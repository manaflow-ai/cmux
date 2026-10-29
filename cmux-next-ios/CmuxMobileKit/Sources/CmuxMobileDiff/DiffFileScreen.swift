#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// SPEC 12.2: one file's diff with a sticky header, unified or split rows,
/// collapsed context that expands, word highlights, and prev/next/viewed in the bottom toolbar.
public struct DiffFileScreen: View {
    @State private var state: DiffViewerState
    @State private var fileID: String
    @State private var expanded: [String: [ClosedRange<Int>]] = [:]
    @ScaledMetric(relativeTo: .footnote) private var codeSize: CGFloat = 13
    @Environment(\.openSessionFile) private var openFile
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewportWidth: CGFloat = 400
    @State private var horizontalOffset: CGFloat = 0
    /// Next / Previous Hunk: the change the last jump went to (this file).
    @State private var hunkLine: Int?
    /// Search in the file (the Mac's Diff: Search): the bar, what is typed, the match shown.
    @State private var searching = false
    @State private var query = ""
    @State private var matchIndex = 0
    @FocusState private var queryFocused: Bool
    /// The line a jump scrolls to (`line-<index>`), with a serial so the same line can be
    /// scrolled to again.
    @State private var scrollTarget: ScrollTarget?

    struct ScrollTarget: Equatable {
        var line: Int
        var serial: Int
    }

    init(state: DiffViewerState, fileID: String) {
        _state = State(initialValue: state)
        _fileID = State(initialValue: fileID)
    }

    /// Opens a file directly (a transcript diff header tap).
    public init(changeSet: DiffChangeSet, fileID: String) {
        self.init(state: DiffViewerState(changeSet: changeSet), fileID: fileID)
    }

    private var files: [DiffFile] { state.changeSet.files }
    private var index: Int { files.firstIndex { $0.id == fileID } ?? 0 }
    private var file: DiffFile { files[index] }

    /// Split needs two readable columns; on a phone the layout stays Unified.
    private var layout: DiffViewerState.Layout {
        DiffLayout.allowsSplit(width: viewportWidth) ? state.layout : .unified
    }

    private var codeFont: UIFont { UIFont.monospacedSystemFont(ofSize: codeSize, weight: .regular) }

    public var body: some View {
        let isViewed = state.viewed.contains(file.id)
        ScrollViewReader { proxy in
            content(isViewed: isViewed)
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    // After the update that unfolds a folded line, so its row exists.
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.cmuxMobileSmooth) { proxy.scrollTo(Self.lineAnchor(target.line), anchor: UnitPoint(x: 0, y: 0.25)) }
                    }
                }
        }
        .onChange(of: fileID) {
            hunkLine = nil
            matchIndex = 0
        }
        .onChange(of: query) {
            // Typing shows the first match; Return and the arrows go on from it.
            matchIndex = 0
            if let first = matches.first { scroll(to: first) }
        }
    }

    private func content(isViewed: Bool) -> some View {
        Group {
            if isViewed {
                ScrollView {
                    Label("Viewed. Tap Viewed to show the diff again.", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            } else if layout == .unified && !state.wrapLines {
                pinnedGutterBody
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(segments) { segment in
                            segmentView(segment)
                        }
                    }
                    .padding(.bottom, 24)
                    .transition(.opacity)
                }
            }
        }
        // Layout changes rebuild the rows (cached row views otherwise keep the old layout).
        .id("\(file.id)|\(layout.rawValue)|\(state.wrapLines)|\(isViewed)")
        .scrollEdgeEffectStyle(.hard, for: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                stickyHeader(isViewed: isViewed)
                if searching { findBar(isViewed: isViewed) }
            }
        }
        .environment(\.diffSearchQuery, searching ? query : "")
        .navigationTitle(file.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(Self.searchTitle, systemImage: "magnifyingglass") {
                    withAnimation(.cmuxMobileSnap) { searching = true }
                    queryFocused = true
                }
                .disabled(isViewed)
                .accessibilityIdentifier("diff.search")
                DiffOptionsMenu(state: state, allowsSplit: DiffLayout.allowsSplit(width: viewportWidth))
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Previous file", systemImage: "chevron.up") { move(-1) }
                    .disabled(index == 0)
                Button("Next file", systemImage: "chevron.down") { move(1) }
                    .disabled(index >= files.count - 1)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                let starts = DiffNavigation.changeStarts(lines)
                Button(Self.previousHunkTitle, systemImage: "chevron.up.2") { jumpHunk(forward: false) }
                    .disabled(isViewed || DiffNavigation.step(starts, from: hunkLine, forward: false) == nil)
                    .accessibilityIdentifier("diff.previousHunk")
                Button(Self.nextHunkTitle, systemImage: "chevron.down.2") { jumpHunk(forward: true) }
                    .disabled(isViewed || DiffNavigation.step(starts, from: hunkLine, forward: true) == nil)
                    .accessibilityIdentifier("diff.nextHunk")
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button {
                    withAnimation(.cmuxMobileSmooth) { state.toggleViewed(file) }
                } label: {
                    // The same name as the header's check ("Viewed"), so the copy above matches it.
                    Label(isViewed ? "Viewed" : "Mark Viewed", systemImage: isViewed ? "checkmark.circle.fill" : "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                        .fixedSize()
                }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) { runDemoCommand() }
        #endif
    }

    // MARK: Unified, unwrapped: pinned gutter + one shared horizontal scroll

    /// Rows as a flat list with fixed heights, so the gutter column and the code column
    /// line up without measuring (GitHub mobile: the numbers and ± stay put while the
    /// code pans).
    enum FlatRow: Identifiable {
        case line(Int)
        case header(id: Int, text: String)
        case collapsed(ClosedRange<Int>)
        case gap(Int)

        var id: String {
            switch self {
            case .line(let index): "l\(index)"
            case .header(let id, _): "h\(id)"
            case .collapsed(let range): "c\(range.lowerBound)"
            case .gap(let index): "g\(index)"
            }
        }
    }

    private var flatRows: [FlatRow] {
        segments.flatMap { segment -> [FlatRow] in
            switch segment {
            case .header(let id, let text): [.header(id: id, text: text)]
            case .collapsed(let range): [.collapsed(range)]
            case .gap(let index): [.gap(index)]
            case .lines(let range): range.map { FlatRow.line($0) }
            }
        }
    }

    private var pinnedGutterBody: some View {
        let lines = lines
        let rows = flatRows
        let current = currentMatchLine
        let rowHeight = DiffLayout.rowHeight(lineHeight: codeFont.lineHeight)
        let codeViewport = DiffLayout.codeViewport(width: viewportWidth)
        let contentWidth = DiffLayout.codeContentWidth(lines: lines, charWidth: codeFont.advancement, viewport: viewportWidth)
        return ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        gutterCell(row, lines: lines, rowHeight: rowHeight, current: current)
                    }
                }
                .frame(width: DiffLayout.gutterWidth)
                .background(Color(uiColor: .systemBackground))
                .zIndex(1)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            codeCell(row, lines: lines, rowHeight: rowHeight, codeViewport: codeViewport)
                        }
                    }
                    .frame(width: contentWidth, alignment: .leading)
                }
                .scrollIndicators(.visible, axes: .horizontal)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, offset in
                    horizontalOffset = max(0, offset)
                }
            }
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func gutterCell(_ row: FlatRow, lines: [DiffLine], rowHeight: CGFloat, current: Int?) -> some View {
        switch row {
        case .line(let index):
            let line = lines[index]
            UnifiedGutter(line: line, isCurrentMatch: current == index)
                .frame(height: rowHeight)
                .id(Self.lineAnchor(index))
        case .header, .gap:
            Color.cmuxMobileDiffHunk.frame(height: DiffLayout.headerRowHeight)
                .accessibilityHidden(true)
        case .collapsed(let range):
            Button { expand(range) } label: {
                Image(systemName: "arrow.up.and.down")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: DiffLayout.headerRowHeight)
                    .background(Color.cmuxMobileDiffHunk)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func codeCell(_ row: FlatRow, lines: [DiffLine], rowHeight: CGFloat, codeViewport: CGFloat) -> some View {
        switch row {
        case .line(let index):
            UnifiedCode(line: lines[index])
                .font(.system(size: codeSize, design: .monospaced))
                .frame(height: rowHeight)
        case .header(_, let text):
            pinnedLabel(Text(text).font(.system(size: 11, design: .monospaced)), codeViewport: codeViewport)
        case .gap:
            pinnedLabel(Text("⋯").font(.system(size: 11, design: .monospaced)), codeViewport: codeViewport)
        case .collapsed(let range):
            Button { expand(range) } label: {
                pinnedLabel(Text(range.count > 40 ? "Expand 20 lines" : "Expand \(range.count) lines").font(.footnote), codeViewport: codeViewport)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Expand \(range.count) hidden lines"))
        }
    }

    /// A full-width band whose label stays in view while the code pans.
    private func pinnedLabel(_ label: Text, codeViewport: CGFloat) -> some View {
        label
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: max(0, codeViewport - 8), alignment: .leading)
            .padding(.leading, 8)
            .offset(x: horizontalOffset)
            .frame(maxWidth: .infinity, minHeight: DiffLayout.headerRowHeight, maxHeight: DiffLayout.headerRowHeight, alignment: .leading)
            .background(Color.cmuxMobileDiffHunk)
            .clipped()
    }

    #if DEBUG
    private func runDemoCommand() {
        switch DemoDirector.shared.command {
        case .diffSetSplit(let split)?:
            withAnimation(.cmuxMobileSmooth) { state.layout = split ? .split : .unified }
        case .diffExpandFirst?:
            if let first = segments.first(where: { if case .collapsed = $0 { return true }; return false }),
               case .collapsed(let range) = first {
                expand(range)
            }
        case .diffMarkViewed?:
            withAnimation(.cmuxMobileSmooth) { state.toggleViewed(file) }
        case .navigateBack?:
            dismiss()
        default:
            break
        }
    }
    #endif

    // MARK: Next / Previous Hunk, Search

    /// The Mac's titles (`action.diffViewerNextHunk`, `…PreviousHunk`, `…Search`, without "Diff:").
    static let nextHunkTitle = "Next Hunk"
    static let previousHunkTitle = "Previous Hunk"
    static let searchTitle = "Search in File"

    static func lineAnchor(_ index: Int) -> String { "line-\(index)" }

    private var matches: [Int] { searching ? DiffNavigation.matches(query, in: lines) : [] }

    private var currentMatchLine: Int? {
        let matches = matches
        return matches.indices.contains(matchIndex) ? matches[matchIndex] : nil
    }

    private func jumpHunk(forward: Bool) {
        guard let line = DiffNavigation.step(DiffNavigation.changeStarts(lines), from: hunkLine, forward: forward) else { return }
        hunkLine = line
        scroll(to: line)
    }

    private func stepMatch(_ delta: Int) {
        let matches = matches
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        scroll(to: matches[matchIndex])
    }

    /// Shows line `index` (unfolding its context when it is folded) and scrolls to it.
    private func scroll(to index: Int) {
        let shown = segments.contains { segment in
            if case .lines(let range) = segment { return range.contains(index) }
            return false
        }
        if !shown, file.hasFullContext {
            expanded[file.id, default: []].append(DiffNavigation.reveal(index, lineCount: lines.count))
        }
        scrollTarget = ScrollTarget(line: anchorLine(for: index), serial: (scrollTarget?.serial ?? 0) + 1)
    }

    /// The line whose row carries the scroll anchor of line `index`: itself, or in Split the first
    /// line of the row that shows it (an added line beside a removed one shares its row).
    private func anchorLine(for index: Int) -> Int {
        guard layout == .split else { return index }
        let lines = lines
        for case .lines(let range) in segments where range.contains(index) {
            return splitRows(Array(lines[range]), from: range.lowerBound).first { $0.lineIndices.contains(index) }?.firstLine ?? index
        }
        return index
    }

    /// The find bar under the file header: the field, "2 of 5", previous and next, Done.
    private func findBar(isViewed: Bool) -> some View {
        let matches = matches
        return HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search in this file", text: $query)
                .focused($queryFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { stepMatch(1) }
                .accessibilityIdentifier("diff.search.field")
            if !query.isEmpty {
                Text(matches.isEmpty ? "No matches" : "\(min(matchIndex + 1, matches.count)) of \(matches.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .accessibilityIdentifier("diff.search.count")
            }
            Button("Previous match", systemImage: "chevron.up") { stepMatch(-1) }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .disabled(matches.isEmpty)
            Button("Next match", systemImage: "chevron.down") { stepMatch(1) }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .disabled(matches.isEmpty)
            Button("Done") {
                withAnimation(.cmuxMobileSnap) { searching = false }
                query = ""
                queryFocused = false
            }
            .fontWeight(.semibold)
            .padding(.leading, 4)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(minHeight: 44)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func move(_ delta: Int) {
        let next = index + delta
        guard files.indices.contains(next) else { return }
        withAnimation(.cmuxMobileSnap) { fileID = files[next].id }
    }

    /// The file header: badge, path (the folder truncates, never the file name), counts,
    /// Mark viewed and File actions (44 pt each). At accessibility sizes the counts and
    /// buttons move to a second line so the file name keeps the width.
    private func stickyHeader(isViewed: Bool) -> some View {
        // The folder takes only the width the whole name leaves, and is left out under
        // about three characters (no sliver or lone glyph).
        let path = FolderNameLayout(folderFirst: true) {
            // `directory` already ends in "/".
            Text(file.directory)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(minWidth: 0, alignment: .leading)
                .clipped()
            Text(file.fileName)
                // At accessibility sizes a long name wraps to a second line instead of losing its middle.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.middle)
        }
        .font(.footnote.monospaced())
        .accessibilityElement(children: .combine)
        let controls = HStack(spacing: 0) {
            DiffCounts(additions: file.additions, deletions: file.deletions)
                .padding(.trailing, 4)
            ViewedToggle(isViewed: isViewed) { withAnimation(.cmuxMobileSmooth) { state.toggleViewed(file) } }
            Menu {
                if openFile.isAvailable, file.status != .deleted {
                    Button("Open File", systemImage: "doc.text.magnifyingglass") { openFile(file.path) }
                }
                Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = file.path }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(.rect)
            }
            .accessibilityLabel("File actions")
        }
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        StatusBadge(status: file.status)
                        path
                    }
                    .padding(.top, 6)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        controls
                    }
                }
            } else {
                HStack(spacing: 10) {
                    StatusBadge(status: file.status)
                    path
                    Spacer(minLength: 4)
                    controls
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: Segments

    enum Segment: Identifiable {
        case header(id: Int, text: String)
        case lines(ClosedRange<Int>)
        case collapsed(ClosedRange<Int>)
        case gap(Int)

        var id: String {
            switch self {
            case .header(let id, _): "h\(id)"
            case .lines(let range): "l\(range.lowerBound)"
            case .collapsed(let range): "c\(range.lowerBound)"
            case .gap(let index): "g\(index)"
            }
        }
    }

    private var lines: [DiffLine] {
        guard state.hideWhitespace else { return file.lines }
        return file.lines.filter { $0.kind == .context || !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var segments: [Segment] {
        let lines = lines
        guard !lines.isEmpty else { return [] }
        guard file.hasFullContext else {
            // Parsed diff: hunk lines with gap markers.
            var result: [Segment] = []
            var start = 0
            for (offset, line) in lines.enumerated() where line.isGap {
                if offset > start { result.append(.lines(start...offset - 1)) }
                result.append(.gap(offset))
                start = offset + 1
            }
            if start < lines.count { result.append(.lines(start...lines.count - 1)) }
            return result
        }
        var visible = DiffFile(path: file.path, status: file.status, lines: lines, hasFullContext: true).hunks().map(\.range)
        if visible.isEmpty { visible = [0...lines.count - 1] }
        // Expanded ranges index the lines as they were (Hide Whitespace changes the count).
        let last = lines.count - 1
        visible += (expanded[file.id] ?? []).compactMap { range in
            range.lowerBound <= last ? range.lowerBound...min(range.upperBound, last) : nil
        }
        visible.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for range in visible {
            if let last = merged.last, range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        var result: [Segment] = []
        var cursor = 0
        for range in merged {
            if range.lowerBound > cursor {
                result.append(.collapsed(cursor...range.lowerBound - 1))
            }
            if range.lowerBound > 0 || cursor == 0 {
                let hunk = DiffFile(path: file.path, status: file.status, lines: lines, hasFullContext: true).hunks(context: 0)
                    .first { range.contains($0.range.lowerBound) }
                if let hunk, range.lowerBound > 0 || result.isEmpty {
                    result.append(.header(id: range.lowerBound, text: headerText(for: range, lines: lines, fallback: hunk.header)))
                }
            }
            result.append(.lines(range))
            cursor = range.upperBound + 1
        }
        if cursor < lines.count {
            result.append(.collapsed(cursor...lines.count - 1))
        }
        return result
    }

    private func headerText(for range: ClosedRange<Int>, lines: [DiffLine], fallback: String) -> String {
        let slice = lines[range]
        let oldStart = slice.first { $0.oldNumber != nil }?.oldNumber ?? 0
        let newStart = slice.first { $0.newNumber != nil }?.newNumber ?? 0
        let suffix = fallback.components(separatedBy: " @@").dropFirst().joined(separator: " @@")
        return "@@ -\(oldStart),\(slice.count { $0.kind != .added }) +\(newStart),\(slice.count { $0.kind != .removed }) @@\(suffix)"
    }

    @ViewBuilder
    private func segmentView(_ segment: Segment) -> some View {
        switch segment {
        case .header(_, let text):
            hunkHeader(text)
        case .gap:
            hunkHeader("⋯")
        case .collapsed(let range):
            Button {
                expand(range)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.and.down").font(.footnote)
                    Text(range.count > 40 ? "Expand 20 lines" : "Expand \(range.count) lines").font(.footnote)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cmuxMobileDiffHunk)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Expand \(range.count) hidden lines"))
        case .lines(let range):
            let lines = lines
            let current = currentMatchLine
            if layout == .split {
                ForEach(splitRows(Array(lines[range]), from: range.lowerBound)) { row in
                    SplitDiffRow(row: row, codeSize: codeSize, wrap: state.wrapLines, columnWidth: (viewportWidth - 1) / 2)
                        .id(Self.lineAnchor(row.firstLine))
                }
            } else {
                ForEach(range, id: \.self) { index in
                    UnifiedDiffRow(line: lines[index], codeSize: codeSize, wrap: state.wrapLines, codeWidth: DiffLayout.codeViewport(width: viewportWidth) - DiffLayout.codeTrailingPadding,
                                   isCurrentMatch: current == index)
                        .id(Self.lineAnchor(index))
                        .transition(.opacity)
                }
            }
        }
    }

    private func hunkHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cmuxMobileDiffHunk)
    }

    private func expand(_ range: ClosedRange<Int>) {
        let chunk: ClosedRange<Int> = range.count > 40 ? range.lowerBound...range.lowerBound + 19 : range
        withAnimation(.cmuxMobileSmooth) {
            expanded[file.id, default: []].append(chunk)
        }
    }

    // MARK: Split pairing

    struct SplitRow: Identifiable {
        let id: Int
        let left: DiffLine?
        let right: DiffLine?
        /// The file's index of the first line this row shows (a jump's anchor).
        var firstLine = 0
        /// The file's indices of the lines this row shows (a context row shows one line on both sides).
        var lineIndices: [Int] = []
    }

    private func splitRows(_ slice: [DiffLine], from start: Int = 0) -> [SplitRow] {
        var rows: [SplitRow] = []
        var dels: [(Int, DiffLine)] = []
        var adds: [(Int, DiffLine)] = []
        func flush() {
            for i in 0..<max(dels.count, adds.count) {
                let indices = [dels[safe: i]?.0, adds[safe: i]?.0].compactMap(\.self)
                rows.append(SplitRow(id: rows.count, left: dels[safe: i]?.1, right: adds[safe: i]?.1,
                                     firstLine: indices.min() ?? start, lineIndices: indices))
            }
            dels = []
            adds = []
        }
        for (offset, line) in slice.enumerated() {
            switch line.kind {
            case .removed:
                if !adds.isEmpty { flush() }
                dels.append((start + offset, line))
            case .added: adds.append((start + offset, line))
            case .context:
                flush()
                rows.append(SplitRow(id: rows.count, left: line, right: line, firstLine: start + offset, lineIndices: [start + offset]))
            }
        }
        flush()
        return rows
    }
}

extension UIFont {
    var advancement: CGFloat {
        ("M" as NSString).size(withAttributes: [.font: self]).width
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension EnvironmentValues {
    /// What Search in File looks for: every match in the shown code is highlighted.
    @Entry var diffSearchQuery = ""
}

/// The background of a Search in File match.
let diffSearchMatch = Color.yellow.opacity(0.45)

/// Code text with word-level highlights (tabs expanded, see `DiffLayout.display`), and the
/// matches of `search`.
func diffText(_ line: DiffLine, dropping prefix: Int = 0, search: String = "") -> AttributedString {
    diffText(DiffLayout.display(line), kind: line.kind, dropping: prefix, search: search)
}

func diffText(_ display: DiffLayout.DisplayLine, kind: DiffLine.Kind, dropping prefix: Int = 0, search: String = "") -> AttributedString {
    let characters = Array(display.text.dropFirst(prefix))
    var text = AttributedString(characters.isEmpty ? " " : String(characters))
    guard !characters.isEmpty else { return text }
    func paint(_ ranges: [Range<Int>], _ color: Color) {
        for range in ranges {
            let lower = max(0, range.lowerBound - prefix)
            let upper = min(characters.count, range.upperBound - prefix)
            guard lower < upper else { continue }
            let start = text.index(text.startIndex, offsetByCharacters: lower)
            let end = text.index(text.startIndex, offsetByCharacters: upper)
            text[start..<end].backgroundColor = color
        }
    }
    paint(display.highlights, kind == .added ? .cmuxMobileDiffAddWord : .cmuxMobileDiffDelWord)
    paint(DiffNavigation.ranges(of: search, in: display.text), diffSearchMatch)
    return text
}

extension DiffLine {
    var markerColor: Color {
        switch kind {
        case .added: .cmuxMobileDiffAddText
        case .removed: .cmuxMobileDiffDelText
        case .context: .secondary
        }
    }

    var rowColor: Color {
        switch kind {
        case .added: .cmuxMobileDiffAddRow
        case .removed: .cmuxMobileDiffDelRow
        case .context: .clear
        }
    }

    var gutterColor: Color {
        switch kind {
        case .added: .cmuxMobileDiffAddGutter
        case .removed: .cmuxMobileDiffDelGutter
        case .context: .clear
        }
    }

    /// VoiceOver's reading of the row. A snippet edit has no line numbers (where it sits in
    /// the file is unknown): it reads without one, never "line 0" (full verify D6).
    var accessibilityText: String {
        func at(_ number: Int?) -> String { number.map { " \($0)" } ?? "" }
        return switch kind {
        case .added: "added line\(at(newNumber)): \(text)"
        case .removed: "removed line\(at(oldNumber)): \(text)"
        case .context: "line\(at(newNumber)): \(text)"
        }
    }
}

/// The pinned part of an unwrapped unified row: old and new numbers and the ± marker.
struct UnifiedGutter: View {
    let line: DiffLine
    /// The line Search in File shows now: an accent bar at the leading edge.
    var isCurrentMatch = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(line.marker)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(line.markerColor)
                .frame(width: DiffLayout.markerWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(line.rowColor)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .leading) {
            line.gutterColor.frame(width: (DiffLayout.numberWidth + DiffLayout.numberTrailingPadding) * 2)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            if isCurrentMatch { Color.accentColor.frame(width: 3).allowsHitTesting(false) }
        }
        .accessibilityHidden(true)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color(uiColor: .tertiaryLabel))
            .lineLimit(1)
            .frame(width: DiffLayout.numberWidth, alignment: .trailing)
            .padding(.trailing, DiffLayout.numberTrailingPadding)
    }
}

/// The scrolled part of an unwrapped unified row: the whole line on one line, never clipped.
struct UnifiedCode: View {
    let line: DiffLine
    @Environment(\.diffSearchQuery) private var search

    var body: some View {
        Text(diffText(line, search: search))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(line.rowColor)
            .contextMenu {
                Button("Copy Line", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
                Button("Copy with Line Number", systemImage: "number") {
                    UIPasteboard.general.string = "\(line.newNumber ?? line.oldNumber ?? 0): \(line.text)"
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(line.accessibilityText))
    }
}

/// A unified row in wrap mode: the height comes from the laid-out text, and wrapped
/// continuations hang at the line's indentation.
struct UnifiedDiffRow: View {
    let line: DiffLine
    let codeSize: CGFloat
    let wrap: Bool
    var codeWidth: CGFloat = 300
    var isCurrentMatch = false
    @Environment(\.diffSearchQuery) private var search

    var body: some View {
        let display = DiffLayout.display(line)
        let font = UIFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
        let indent = DiffLayout.hangingIndent(display, charWidth: font.advancement, codeWidth: codeWidth)
        let dropped = min(display.indent, Int((indent / max(font.advancement, 1)).rounded(.down)))
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            gutter(line.oldNumber)
            gutter(line.newNumber)
            Text(line.marker)
                .frame(width: DiffLayout.markerWidth)
                .foregroundStyle(line.markerColor)
            Text(diffText(display, kind: line.kind, dropping: dropped, search: search))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, indent)
                .padding(.trailing, DiffLayout.codeTrailingPadding)
        }
        .font(.system(size: codeSize, design: .monospaced))
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            line.gutterColor.frame(width: (DiffLayout.numberWidth + DiffLayout.numberTrailingPadding) * 2)
        }
        .background(line.rowColor)
        .overlay(alignment: .leading) {
            if isCurrentMatch { Color.accentColor.frame(width: 3).allowsHitTesting(false) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contextMenu {
            Button("Copy Line", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
            Button("Copy with Line Number", systemImage: "number") {
                UIPasteboard.general.string = "\(line.newNumber ?? line.oldNumber ?? 0): \(line.text)"
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(line.accessibilityText))
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color(uiColor: .tertiaryLabel))
            .frame(width: DiffLayout.numberWidth, alignment: .trailing)
            .padding(.trailing, DiffLayout.numberTrailingPadding)
    }
}

struct SplitDiffRow: View {
    let row: DiffFileScreen.SplitRow
    let codeSize: CGFloat
    let wrap: Bool
    let columnWidth: CGFloat
    @Environment(\.diffSearchQuery) private var search

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(row.left, number: row.left?.oldNumber)
            Divider()
            side(row.right, number: row.right?.newNumber)
        }
        .font(.system(size: codeSize, design: .monospaced))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func side(_ line: DiffLine?, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 2)
            if let line {
                Text(diffText(line, search: search))
                    .lineLimit(wrap ? nil : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
        }
        .frame(width: columnWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(background(line))
    }

    private func background(_ line: DiffLine?) -> Color {
        guard let line else { return Color.cmuxMobileFill }
        switch line.kind {
        case .added: return .cmuxMobileDiffAddRow
        case .removed: return .cmuxMobileDiffDelRow
        case .context: return .clear
        }
    }
}
#endif
