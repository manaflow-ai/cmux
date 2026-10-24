#if os(iOS)
import CmuxMobileDesign
import CmuxMobileDiff
import CmuxMobileMarkdown
import SwiftUI

/// Opens the diff viewer (`fileID` nil = the file list).
public struct OpenDiffAction: Sendable {
    let handler: @MainActor @Sendable (DiffChangeSet, String?) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (DiffChangeSet, String?) -> Void) {
        self.handler = handler
    }

    @MainActor public func callAsFunction(_ changes: DiffChangeSet, file: String? = nil) {
        handler(changes, file)
    }
}

extension EnvironmentValues {
    @Entry public var openDiff = OpenDiffAction { _, _ in }
}

/// SPEC 6.4 tool row: 32 pt, 15 pt symbol, verb + mono object, chevron that rotates.
struct ToolRowView: View {
    let call: ACPToolCall
    @State private var expanded = false
    @Environment(\.openSessionFile) private var openFile
    private let wording = ToolWording()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.cmuxMobileSmooth) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            // The 44 pt target overlaps the gaps between rows (a 32 pt row in the layout).
            .padding(.vertical, -6)
            if expanded {
                ToolOutputView(call: call)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .accessibilityElement(children: .contain)
        // The files the call read or wrote open in the preview (long press).
        .contextMenu {
            if openFile.isAvailable {
                ForEach(Array(call.locations.prefix(5).enumerated()), id: \.offset) { _, location in
                    Button("Open \((location.path as NSString).lastPathComponent)", systemImage: "doc.text.magnifyingglass") {
                        openFile(location.path, line: location.line)
                    }
                }
            }
            if let path = call.locations.first?.path {
                Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
            }
        }
    }

    private var header: some View {
        let (verb, object) = wording.verb(call)
        return HStack(spacing: 8) {
            Image(systemName: wording.symbol(call))
                .font(.system(size: 14))
                .foregroundStyle(call.isFailed ? Color.cmuxMobileDanger : .secondary)
                .frame(width: 18)
            Group {
                if call.isRunning {
                    WorkingLabel(verb, font: .subheadline)
                } else {
                    Text(verb).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)
            if let object {
                Text(object)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Commands cut at the tail (a token cut in the middle reads wrong);
                    // paths keep the middle cut so the file name stays.
                    .truncationMode(call.kind == .execute ? .tail : .middle)
            }
            if let code = call.exitCode, code != 0 {
                Text("Exit \(code)").font(.footnote).foregroundStyle(Color.cmuxMobileDanger)
            }
            Spacer(minLength: 4)
            if call.isRunning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        // 44 pt hit target; the Button's container pulls the row back to 32 pt of layout.
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

/// Expanded output: a code card; bash shows `$ command` first; capped at 12 lines.
struct ToolOutputView: View {
    let call: ACPToolCall

    var body: some View {
        let output = call.outputText
        if call.kind == .execute {
            let command = call.command.map { "$ \($0)\n" } ?? ""
            CodeCard(language: "bash", code: command + (output.isEmpty ? "(no output)" : output), title: "Bash", maxHeight: 12 * 19 + 60)
        } else if !output.isEmpty {
            CodeCard(language: call.locations.first.map { ($0.path as NSString).pathExtension } ?? nil, code: output,
                     title: call.locations.first?.path ?? call.title, maxHeight: 12 * 19 + 60)
        } else {
            Text(call.isRunning ? "Loading output…" : "No output.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.leading, 26)
        }
    }
}

/// A run of tool calls as one row; expanded while running (latest visible), collapsed after.
struct ToolGroupView: View {
    let calls: [ACPToolCall]
    let turnRunning: Bool
    @State private var userExpanded: Bool?
    private let wording = ToolWording()

    private var expanded: Bool { userExpanded ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.cmuxMobileSmooth) { userExpanded = !expanded }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: calls.contains(where: \.isFailed) ? "exclamationmark.triangle.fill" : "square.stack.3d.down.right")
                        .font(.system(size: 14))
                        .foregroundStyle(calls.contains(where: \.isFailed) ? Color.cmuxMobileDanger : .secondary)
                        .frame(width: 18)
                    // The summary changes as calls arrive and finish: swap the
                    // label in place, never crossfade old and new text.
                    if calls.contains(where: \.isRunning) {
                        WorkingLabel(wording.summary(calls), font: .subheadline).transition(.identity)
                    } else {
                        Text(wording.summary(calls)).font(.subheadline).foregroundStyle(.secondary).transition(.identity)
                    }
                    Spacer(minLength: 4)
                    if let duration = groupDuration {
                        Text(wording.duration(duration)).font(.footnote.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                // 44 pt hit target on a 32 pt row (the extra overlaps the row gaps).
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.vertical, -6)
            // The header's 44 pt target overlaps the first call's: the header
            // wins, so a tap on it always closes the group.
            .zIndex(1)
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(calls) { call in
                        ToolRowView(call: call)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color(uiColor: .separator)).frame(width: 1).padding(.leading, 8).padding(.vertical, 6)
                }
                .transition(.opacity)
            } else if let live = calls.last(where: \.isRunning) {
                ToolRowView(call: live)
                    // Each running call is its own row: one call's expansion
                    // does not carry over to the next.
                    .id(live.id)
                    .padding(.leading, 12)
                    .transition(.opacity)
            }
        }
    }

    private var groupDuration: TimeInterval? {
        guard !calls.contains(where: \.isRunning),
              let start = calls.compactMap(\.startedAt).min(), let end = calls.compactMap(\.endedAt).max() else { return nil }
        return end.timeIntervalSince(start)
    }
}

/// Collapsed "Thought" row; expands to the reasoning text in label2. While
/// the agent thinks it shows the last three lines until the person closes it.
struct ThoughtRow: View {
    let text: String
    let isLive: Bool
    @State private var choice = DisclosureChoice()

    private var expanded: Bool { choice.isOpen(automatic: isLive) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.cmuxMobileSmooth) { choice.toggle(automatic: isLive) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 18)
                    if isLive {
                        WorkingLabel("Thinking", font: .subheadline)
                    } else {
                        Text("Thought").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                // 44 pt hit target on a 32 pt row (the extra overlaps the row gaps).
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.vertical, -6)
            if expanded {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(choice.chosen == true ? nil : 3)
                    .padding(.leading, 26)
                    .transition(.opacity)
            }
        }
    }
}

/// SPEC 6.8 `DiffSnippet`: header "Edited `File.swift` +12 −4 Open", text-colored unified lines, max 12.
struct DiffSnippet: View {
    let call: ACPToolCall
    let changeSet: DiffChangeSet
    @Environment(\.openSessionFile) private var openFile
    @Environment(\.openDiff) private var openDiff
    @State private var showAll = false
    @ScaledMetric(relativeTo: .footnote) private var codeSize: CGFloat = 13
    /// Settings → Terminal → Wrap code and diff lines.
    @AppStorage(CmuxMobilePreferences.Key.wrapCode) private var wrapCode = CmuxMobilePreferences.defaultWrapCode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(files, id: \.id) { file in
                card(file)
            }
        }
    }

    private var files: [DiffFile] {
        call.diffs.map { DiffFile(path: $0.path, edits: [($0.oldText, $0.newText)]) }
    }

    private func card(_ file: DiffFile) -> some View {
        let preview = file.unifiedPreview(maxLines: showAll ? 400 : 12)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                openDiff(changeSet, file: file.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: call.isRunning ? "pencil" : (file.status == .added ? "doc.badge.plus" : "pencil"))
                        .font(.system(size: 13))
                    Text(file.status == .added ? "Created" : "Edited").font(.footnote.weight(.medium))
                    Text(file.fileName).font(.footnote.monospaced().weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    DiffCounts(additions: file.additions, deletions: file.deletions)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Edited \(file.fileName), \(file.additions) additions, \(file.deletions) deletions. Open diff"))
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(line.kind == .added ? "+" : (line.kind == .removed ? "−" : " "))
                                .frame(width: 14, alignment: .leading)
                            Text(line.text.isEmpty ? " " : line.text)
                        }
                        .foregroundStyle(color(line))
                    }
                }
                .font(.system(size: codeSize, design: .monospaced))
                .lineSpacing(4)
                .fixedSize(horizontal: !wrapCode, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, preview.remaining > 0 ? 4 : 16)
                // Wrapping: as wide as the card, so lines break instead of scrolling.
                .containerRelativeFrame(wrapCode ? .horizontal : [], alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .trailingOverflowFade()
            if preview.remaining > 0 {
                Button(preview.remaining == 1 ? "Show 1 more line" : "Show \(preview.remaining) more lines") {
                    withAnimation(.cmuxMobileSmooth) { showAll = true }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(.rect)
                .padding(.bottom, 2)
            }
        }
        .background(Color.cmuxMobileCodeBackground, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5)
        }
        .contextMenu {
            Button("Open Diff", systemImage: "arrow.up.right.square") { openDiff(changeSet, file: file.id) }
            if openFile.isAvailable, file.status != .deleted {
                Button("Open File", systemImage: "doc.text.magnifyingglass") { openFile(file.path) }
            }
            Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = file.path }
        }
    }

    private func color(_ line: DiffLine) -> Color {
        switch line.kind {
        case .added: .cmuxMobileDiffAddText
        case .removed: .cmuxMobileDiffDelText
        case .context: .secondary
        }
    }
}

/// SPEC 6.8 turn summary + acpmux edited-files card: "3 files changed +40 −12", one row per file.
struct EditedFilesCard: View {
    let changeSet: DiffChangeSet
    @Environment(\.openDiff) private var openDiff
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                openDiff(changeSet)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.forwardslash.minus").font(.system(size: 14))
                    // Accessibility sizes stack the counts under the title instead of truncating both.
                    let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 8))
                    layout {
                        Text("\(changeSet.files.count) \(changeSet.files.count == 1 ? "file" : "files") changed").font(.subheadline.weight(.semibold))
                        DiffCounts(additions: changeSet.additions, deletions: changeSet.deletions).fixedSize()
                    }
                    Spacer(minLength: 4)
                    if !typeSize.isAccessibilitySize {
                        Text("Review").font(.subheadline.weight(.semibold))
                    }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(minHeight: 48)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 16)
            ForEach(changeSet.files) { file in
                Button {
                    openDiff(changeSet, file: file.id)
                } label: {
                    HStack(spacing: 10) {
                        // Viewed (the shared `DiffViewedStore`): marked in Changes, Review or the file screen.
                        let viewed = DiffViewedStore.shared.isViewed(file)
                        Image(systemName: viewed ? "checkmark.circle.fill" : (file.status == .added ? "doc.badge.plus" : "doc.text"))
                            .font(.system(size: 13)).foregroundStyle(viewed ? Color.cmuxMobileSuccess : .secondary).frame(width: 18)
                            .accessibilityLabel(viewed ? Text("Viewed") : Text(""))
                        if typeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 2) {
                                // The whole name at full size, wrapping when it must (every name
                                // the same size); the smaller folder goes under it and truncates first.
                                Text(file.fileName).font(.subheadline.monospaced()).lineLimit(3)
                                    .truncationMode(.middle)
                                if !file.directory.isEmpty {
                                    Text(file.directory).font(.footnote).foregroundStyle(.tertiary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                DiffCounts(additions: file.additions, deletions: file.deletions).fixedSize()
                            }
                            Spacer(minLength: 0)
                        } else {
                            // The folder gets only what the whole name leaves, or nothing (no sliver).
                            FolderNameLayout(folderFirst: false, spacing: 10) {
                                Text(file.fileName).font(.subheadline.monospaced()).lineLimit(1).truncationMode(.middle)
                                Text(file.directory).font(.footnote).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                                    .frame(minWidth: 0, alignment: .leading)
                                    .clipped()
                            }
                            .layoutPriority(1)
                            Spacer(minLength: 4)
                            DiffCounts(additions: file.additions, deletions: file.deletions)
                                .fixedSize()
                                .layoutPriority(2)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.cmuxMobileCard, in: .rect(cornerRadius: 20, style: .continuous))
    }
}
#endif
