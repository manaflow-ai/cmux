#if os(iOS)
import CmuxMobileDesign
import CmuxMobileDiff
import CmuxMobileMarkdown
import CmuxSpinner
import SwiftUI
import UIKit

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
    @State private var localExpanded = false
    @Environment(\.openSessionFile) private var openFile
    @Environment(\.chatDisclosures) private var disclosures
    @Environment(\.transcriptFoldHold) private var holdFold
    private let wording = ToolWording()

    /// Kept by the transcript when it has a store (its rows are reused cells), else here.
    private var expanded: Bool { disclosures?.isOpen("tool-\(call.id)") ?? localExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                toggleDisclosure(holdFold, key: "tool-\(call.id)", in: disclosures) {
                    if let disclosures { disclosures.set("tool-\(call.id)", !expanded) } else { localExpanded.toggle() }
                }
            } label: {
                header
            }
            .buttonStyle(.cmuxPressLine)
            // Keep row actions on the tappable header. Expanded output owns text selection.
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
            // The 44 pt target overlaps the gaps between rows (a 32 pt row in the layout).
            .padding(.vertical, -6)
            // Its pictures always show: a screenshot or an image the agent sent is what the
            // row is, not output to open (`outputText` left them out, so they drew nothing).
            if call.hasImages {
                ToolOutputImages(call: call)
            }
            if expanded {
                // Grows down from under the row, never slides in over it.
                ToolOutputView(call: call)
                    .transition(.disclosureReveal)
            }
        }
        .accessibilityElement(children: .contain)
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
                CmuxSpinner().controlSize(.mini)
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

/// What an expanded tool call draws under its card: nothing while its cut output's rest is read
/// (the head stays in the card), a quiet line only once the read failed (it is read again on its own).
enum ToolOutputFooter {
    static func shows(cut: Bool, failed: Bool) -> Bool { cut && failed }
}

/// Expanded output: a code card; bash shows `$ command` first; capped at 12 lines. An output
/// the Mac sent cut (a page's oversized one) shows its head and reads the rest as it opens.
struct ToolOutputView: View {
    let call: ACPToolCall
    @Environment(\.loadFullToolOutput) private var loadFull
    /// The whole output's read failed (the link was down: the hub answers nil until it is
    /// ready). Read again on its own (AutoRetry), never a Try Again button.
    @State private var loadFailed = false
    @State private var autoRetry = AutoRetry()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            card
            // The head the Mac sent stays drawn while the rest is read, and the whole text
            // takes its place in the same card (capped at the same height): no "Loading the full
            // output…" line that comes and goes under it. Leo, 2026-11-24: "wer need to chase
            // all these placeholders doen and prevent them". Only a failed read adds a line, and
            // only once the quiet bound passes: it is read again on its own, never a button.
            if ToolOutputFooter.shows(cut: call.outputCut != nil, failed: loadFailed), autoRetry.isQuietLineShown {
                AutoRetryQuietLine(autoRetry, Text("Still loading the full output…"))
                    .padding(.leading, 26)
            }
        }
        .task(id: call.outputCut) {
            guard call.outputCut != nil else { return }
            loadFailed = !(await loadFull(call))
        }
        .autoRetry(autoRetry, failing: loadFailed && call.outputCut != nil) {
            guard call.outputCut != nil else { loadFailed = false; return }
            loadFailed = !(await loadFull(call))
        }
    }

    @ViewBuilder
    private var card: some View {
        let output = call.outputText
        if call.kind == .execute {
            let command = call.command.map { "$ \($0)\n" } ?? ""
            CodeCard(language: "bash", code: command + (output.isEmpty ? "(no output)" : output), title: "Bash", maxHeight: 12 * 19 + 60)
        } else if !output.isEmpty {
            CodeCard(language: call.locations.first.map { ($0.path as NSString).pathExtension } ?? nil, code: output,
                     title: call.locations.first?.path ?? call.title, maxHeight: 12 * 19 + 60)
        } else if call.hasImages {
            // Its pictures are drawn under its line (`ToolOutputImages`).
            EmptyView()
        } else {
            Text(call.isRunning ? "Loading output…" : "No output.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.leading, 26)
        }
    }
}

/// The pictures in a call's output (ACP `image` blocks), each drawn as the image it is, fit in
/// `maxHeight`. One whose bytes do not decode shows what it is (its type and size), never a
/// waiting state. Plain SwiftUI images, so a tab card's still draws them too.
struct ToolOutputImages: View {
    let call: ACPToolCall
    static let maxHeight: CGFloat = 240
    /// The pictures one row draws (a call rarely holds more than one or two).
    static let maxShown = 8

    var body: some View {
        let images = Array(call.images.prefix(Self.maxShown))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(images.indices, id: \.self) { index in // visible-only: at most maxShown (8) pictures of one call, in the order the call holds them
                let image = images[index]
                if let picture = ToolImageCache.image(key: "\(call.id)#\(index)", base64: image.data) {
                    Image(uiImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 320, maxHeight: Self.maxHeight, alignment: .leading)
                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel(Text("Image"))
                } else {
                    Label(ToolImageCache.describe(mimeType: image.mimeType, base64: image.data), systemImage: "photo")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Decoded tool output pictures, by call and index: decoded once (downscaled to what a row
/// shows), not on every pass of a row's body.
@MainActor
enum ToolImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()
    /// Keys whose bytes did not decode: not tried again on every pass.
    private static var failed: Set<String> = []

    static func image(key: String, base64: String) -> UIImage? {
        if let image = cache.object(forKey: key as NSString) { return image }
        guard !failed.contains(key) else { return nil }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), let full = UIImage(data: data) else {
            failed.insert(key)
            return nil
        }
        // A row shows at most 320 x 240 pt: the decoded bitmap need not be bigger (3x).
        let longest = max(full.size.width, full.size.height)
        let image = longest > 960
            ? full.preparingThumbnail(of: CGSize(width: full.size.width * 960 / longest, height: full.size.height * 960 / longest)) ?? full
            : full
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    /// "PNG image, 34 KB": what an image whose bytes do not decode is.
    static func describe(mimeType: String, base64: String) -> String {
        let kind = mimeType.split(separator: "/").last.map { $0.uppercased() } ?? "Image"
        let bytes = Int64(base64.utf8.count) * 3 / 4
        return "\(kind) image, \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}

/// A run of tool calls as one row; expanded while running (latest visible), collapsed after.
struct ToolGroupView: View {
    let calls: [ACPToolCall]
    let turnRunning: Bool
    @State private var userExpanded: Bool?
    @Environment(\.chatDisclosures) private var disclosures
    @Environment(\.transcriptFoldHold) private var holdFold
    private let wording = ToolWording()

    private var key: String { "group-\(calls.first?.id ?? "")" }
    private var expanded: Bool { (disclosures.map { $0.isOpen(key) } ?? userExpanded) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                toggleDisclosure(holdFold, key: key, in: disclosures) {
                    if let disclosures { disclosures.set(key, !expanded) } else { userExpanded = !expanded }
                }
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
            .buttonStyle(.cmuxPressLine)
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
                .transition(.disclosureReveal)
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
        return wording.shown(end.timeIntervalSince(start))
    }
}

/// Collapsed "Thought" row; expands to the reasoning text in label2. While
/// the agent thinks it shows the last three lines until the person closes it.
struct ThoughtRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let text: String
    let isLive: Bool
    /// The transcript's key for the person's choice (its rows are reused cells).
    var id: String?
    @State private var localChoice = DisclosureChoice()
    @Environment(\.chatDisclosures) private var disclosures

    private var choice: DisclosureChoice {
        get {
            guard let id, let disclosures else { return localChoice }
            return DisclosureChoice(chosen: disclosures.isOpen("thought-\(id)"))
        }
        nonmutating set {
            guard let id, let disclosures else { localChoice = newValue; return }
            disclosures.set("thought-\(id)", newValue.chosen)
        }
    }
    @Environment(\.transcriptFoldHold) private var holdFold

    private var expanded: Bool { choice.isOpen(automatic: isLive) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                toggleDisclosure(holdFold, key: id.map { "thought-\($0)" }, in: disclosures) { choice.toggle(automatic: isLive) }
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
            .buttonStyle(.cmuxPressLine)
            .padding(.vertical, -6)
            if expanded {
                // Opened by the person: all of it. Opened because it is live: its newest
                // lines (a line limit alone keeps the first three, which stop changing).
                let font = NativeTextStyles(category: UIContentSizeCategory(typeSize)).font(.subheadline)
                SelectableText(choice.chosen == true ? text : DisclosureChoice.liveTail(of: text),
                               font: font, color: .secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    // Clip the full label from the top so the overlay hits the same visible word.
                    .frame(maxHeight: choice.chosen == true ? nil : ceil(font.lineHeight * 3), alignment: .bottom)
                    .clipped()
                    .padding(.leading, 26)
                    .transition(.disclosureReveal)
            }
        }
    }
}

/// SPEC 6.8 `DiffSnippet`: header "Edited `File.swift` +12 −4 Open", text-colored unified lines, max 12.
struct DiffSnippet: View {
    let call: ACPToolCall
    /// One file per diff of the call with its preview lines, computed once off the main
    /// thread (`ChatDiffCache`); nil while it computes (the header shows, the lines follow).
    let previews: [ChatDiffCache.EditPreview]?
    /// The turn's changes, built when the diff opens (not per body), off the main thread.
    let changeSet: () async -> DiffChangeSet
    @Environment(\.openSessionFile) private var openFile
    @Environment(\.openDiff) private var openDiff
    @Environment(\.chatDisclosures) private var disclosures
    @State private var localShowAll = false
    private var showAll: Bool { disclosures?.isOpen("diff-\(call.id)") ?? localShowAll }
    @ScaledMetric(relativeTo: .footnote) private var codeSize: CGFloat = 13
    /// Settings → Terminal → Wrap code and diff lines.
    @AppStorage(CmuxMobilePreferences.Key.wrapCode) private var wrapCode = CmuxMobilePreferences.defaultWrapCode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let previews {
                ForEach(previews, id: \.file.id) { preview in
                    card(preview)
                }
            } else {
                ForEach(Array(call.diffs.enumerated()), id: \.offset) { _, diff in
                    pendingCard(path: diff.path, added: diff.oldText == nil)
                }
            }
        }
    }

    /// The card's header while the diff computes (a large rewrite takes a moment).
    private func pendingCard(path: String, added: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: added ? "doc.badge.plus" : "pencil").font(.system(size: 13))
            Text(added ? "Created" : "Edited").font(.footnote.weight(.medium))
            Text((path as NSString).lastPathComponent).font(.footnote.monospaced().weight(.medium)).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 4)
            CmuxSpinner().controlSize(.mini)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .cmuxMobileContentSurface(.card, in: .rect(cornerRadius: 20, style: .continuous))
    }

    /// Opens the diff once the turn's changes are ready (the cache has them, or computes
    /// them off the main thread).
    private func open(_ fileID: String) {
        let changeSet = changeSet
        let openDiff = openDiff
        Task { @MainActor in openDiff(await changeSet(), file: fileID) }
    }

    private func card(_ edit: ChatDiffCache.EditPreview) -> some View {
        let file = edit.file
        let preview = showAll ? edit.long : edit.short
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                open(file.id)
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
            .buttonStyle(.cmuxPressFill)
            .contextMenu {
                Button("Open Diff", systemImage: "arrow.up.right.square") { open(file.id) }
                if openFile.isAvailable, file.status != .deleted {
                    Button("Open File", systemImage: "doc.text.magnifyingglass") { openFile(file.path) }
                }
                Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = file.path }
            }
            .accessibilityLabel(Text("Edited \(file.fileName), \(file.additions) additions, \(file.deletions) deletions. Open diff"))
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(preview.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(line.kind == .added ? "+" : (line.kind == .removed ? "−" : " "))
                                .frame(width: 14, alignment: .leading)
                            SelectableText(line.text.isEmpty ? " " : line.text,
                                           font: .monospacedSystemFont(ofSize: codeSize, weight: .regular),
                                           color: UIColor(color(line)), lineSpacing: 4)
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
                    withAnimation(.cmuxMobileSmooth.unlessReduceMotion) {
                        if let disclosures { disclosures.set("diff-\(call.id)", true) } else { localShowAll = true }
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(.rect)
                .padding(.bottom, 2)
            }
        }
        .cmuxMobileContentSurface(.card, in: .rect(cornerRadius: 20, style: .continuous))
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
            .buttonStyle(.cmuxPressFill)
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
                .buttonStyle(.cmuxPressFill)
            }
        }
        .cmuxMobileContentSurface(.card, in: .rect(cornerRadius: 20, style: .continuous))
    }
}
#endif
