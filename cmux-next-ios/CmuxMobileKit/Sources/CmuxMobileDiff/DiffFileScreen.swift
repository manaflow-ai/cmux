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
    /// The rows, texts and heights, prepared off the main thread once per (file, options, style).
    @State private var renderer = DiffRenderer()
    /// Next / Previous Hunk: the change the last jump went to (this file).
    @State private var hunkLine: Int?
    /// Search in the file (the Mac's Diff: Search): the bar, what is typed, the match shown.
    @State private var searching = false
    @State private var query = ""
    @State private var matchIndex = 0
    @FocusState private var queryFocused: Bool
    /// The line a jump scrolls to, with a serial so the same line can be scrolled to again.
    @State private var scrollTarget: DiffScrollTarget?

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

    /// What the list shows and how: a change prepares a new render model.
    private var renderKey: DiffRenderKey {
        let layout = layout
        let wrap = state.wrapLines
        let split = layout == .split
        return DiffRenderKey(
            fileID: file.id, contentHash: file.contentHash,
            options: DiffRows.Options(hideWhitespace: state.hideWhitespace, split: split, expanded: expanded[file.id] ?? []),
            // Unwrapped unified rows do not depend on the width (the layout fills it).
            style: DiffRenderStyle(codeSize: codeSize, wrap: wrap, split: split, width: wrap || split ? viewportWidth.rounded() : 0,
                                   search: searching ? query.trimmingCharacters(in: .whitespacesAndNewlines) : "")
        )
    }

    public var body: some View {
        let isViewed = state.isViewed(file)
        let file = file
        let renderKey = renderKey
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
                .scrollEdgeEffectStyle(.hard, for: .top)
            } else if let model = renderer.model, model.key.fileID == file.id {
                DiffCodeList(model: model, currentLine: currentMatchLine, scrollTarget: scrollTarget) { expand($0) }
                    .ignoresSafeArea(.container, edges: .bottom)
                    .transition(.opacity)
            } else {
                Color(uiColor: .systemBackground)
            }
        }
        .task(id: renderKey) { await renderer.update(file: file, key: renderKey) }
        .onChange(of: fileID) {
            hunkLine = nil
            matchIndex = 0
            // The last file's jump: a new list (its coordinator has scrolled to nothing yet)
            // would otherwise take it and scroll the new file to that line.
            scrollTarget = nil
        }
        .onChange(of: state.hideWhitespace) { wasHidden, hides in
            // `hunkLine` indexes the shown lines; keep it on the same line of the file.
            hunkLine = DiffNavigation.remap(hunkLine,
                                            from: DiffNavigation.visibleLines(file.lines, hideWhitespace: wasHidden),
                                            to: DiffNavigation.visibleLines(file.lines, hideWhitespace: hides))
        }
        .onChange(of: query) {
            // Typing shows the first match; Return and the arrows go on from it.
            matchIndex = 0
            if let first = matches.first { scroll(to: first) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                stickyHeader(isViewed: isViewed)
                if searching { findBar(isViewed: isViewed) }
            }
        }
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
        #if DEBUG
        .onChange(of: DemoDirector.shared.serial) { runDemoCommand() }
        #endif
    }

    #if DEBUG
    private func runDemoCommand() {
        switch DemoDirector.shared.command {
        case .diffSetSplit(let split)?:
            withAnimation(.cmuxMobileSmooth) { state.layout = split ? .split : .unified }
        case .diffExpandFirst?:
            if let range = renderer.model?.rows.firstCollapsed { expand(range) }
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

    /// The file's lines as shown (Hide Whitespace drops blank-only changes), as `DiffRows` shows them.
    private var lines: [DiffLine] { DiffNavigation.visibleLines(file.lines, hideWhitespace: state.hideWhitespace) }

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
        let lines = lines
        let shown = DiffRows.segments(lines: lines, hasFullContext: file.hasFullContext, expanded: expanded[file.id] ?? []).contains { segment in
            if case .lines(let range) = segment { return range.contains(index) }
            return false
        }
        if !shown, file.hasFullContext {
            expanded[file.id, default: []].append(DiffNavigation.reveal(index, lineCount: lines.count))
        }
        // The list scrolls once its rows show the line (after the unfold lands).
        scrollTarget = DiffScrollTarget(line: index, serial: (scrollTarget?.serial ?? 0) + 1)
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

    private func expand(_ range: ClosedRange<Int>) {
        let chunk: ClosedRange<Int> = range.count > 40 ? range.lowerBound...range.lowerBound + 19 : range
        withAnimation(.cmuxMobileSmooth) {
            expanded[file.id, default: []].append(chunk)
        }
    }
}

extension DiffLine {
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

#endif
