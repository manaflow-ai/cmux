#if os(iOS)
import CmuxMobileDiff
import CmuxMobileMarkdown
import SwiftUI
import UIKit

/// What a native row does with taps and long presses: the same intents and menus as the
/// SwiftUI row it stands in for.
@MainActor
enum ChatNativeRowActions {
    static func configure(_ actions: inout ChatNativeActions, row: ChatRow, context: ChatRowContext) {
        let store = context.store
        let surface = context.surface
        let disclosures = surface.disclosures
        switch row.kind {
        case .prompt(let text, _, let at, let isLast):
            let turnID = row.turnID
            actions.menu = { _ in
                var items: [UIMenuElement] = [
                    UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = text },
                    UIAction(title: "Select Text", image: UIImage(systemName: "selection.pin.in.out")) { _ in ChatSelectText.present(text) },
                ]
                if isLast {
                    items.append(UIAction(title: "Edit and Resend", image: UIImage(systemName: "pencil")) { _ in context.editAndResend(turnID: turnID) })
                } else if context.canEditEarlier(turnID: turnID) {
                    // An earlier prompt: edited in its own sheet, sent in a copy of the chat forked before it.
                    items.append(UIAction(title: "Edit and Resend", image: UIImage(systemName: "pencil")) { _ in context.editEarlier(turnID: turnID) })
                }
                items.append(UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in ChatShare.present(text) })
                items += ChatPolishMenus.promptItems(turnID: turnID, text: text, store: store)
                return UIMenu(children: [UIMenu(title: AgentTurn.menuTimestamp(at), options: .displayInline, children: items)])
            }
        case .tool(let call):
            let openFile = context.openFile
            actions.menu = { _ in
                var items: [UIMenuElement] = []
                if openFile.isAvailable {
                    for location in call.locations.prefix(5) {
                        items.append(UIAction(title: "Open \((location.path as NSString).lastPathComponent)",
                                              image: UIImage(systemName: "doc.text.magnifyingglass")) { _ in openFile(location.path, line: location.line) })
                    }
                }
                if let path = call.locations.first?.path {
                    items.append(UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = path })
                }
                return items.isEmpty ? nil : UIMenu(children: items)
            }
        case .edit(let call, let files):
            let turnID = row.turnID
            let openDiff = context.openDiff
            let openFile = context.openFile
            actions.hit = { hit in
                switch hit {
                case .openDiff(let file):
                    Task { @MainActor in openDiff(await context.changeSet(turnID: turnID, fallbackID: call.id), file: file) }
                case .toggle(let key): toggleDisclosure(context.foldHold, key: key, in: disclosures) { disclosures.set(key, true) }
                default: break
                }
            }
            actions.menu = { pressed in
                // The card pressed (a snippet shows one card per file it edited).
                guard let file = files?.first(where: { $0.file.id == pressed })?.file ?? files?.first?.file else { return nil }
                var items: [UIMenuElement] = [
                    UIAction(title: "Open Diff", image: UIImage(systemName: "arrow.up.right.square")) { _ in
                        Task { @MainActor in openDiff(await context.changeSet(turnID: turnID, fallbackID: call.id), file: file.id) }
                    },
                ]
                if openFile.isAvailable, file.status != .deleted {
                    items.append(UIAction(title: "Open File", image: UIImage(systemName: "doc.text.magnifyingglass")) { _ in openFile(file.path) })
                }
                items.append(UIAction(title: "Copy Path", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = file.path })
                return UIMenu(children: items)
            }
            return
        case .editedFiles(let changes):
            let openDiff = context.openDiff
            actions.viewed = viewed(changes)
            actions.menu = { _ in nil }
            actions.hit = { hit in
                if case .openDiff(let file) = hit { openDiff(changes, file: file) }
            }
            return
        case .actions(let turn, _):
            actions.menu = { _ in nil }
            actions.moreMenu = {
                var items: [UIMenuElement] = [
                    UIAction(title: "Copy as Markdown", image: UIImage(systemName: "text.document")) { _ in UIPasteboard.general.string = turn.answerMarkdown },
                    UIAction(title: "Retry", image: UIImage(systemName: "arrow.clockwise")) { _ in store.retry(turn) },
                ]
                // Retry with another model (`RetryModelChoice`), read when the menu opens.
                if !store.retryModels.isEmpty {
                    let models = store.retryModels.map { model in
                        UIAction(title: model.name, image: model.id == store.currentModelID ? UIImage(systemName: "checkmark") : nil) { _ in
                            store.retry(turn, model: model.id)
                        }
                    }
                    items.append(UIMenu(title: RetryModelChoice.title, image: UIImage(systemName: "arrow.triangle.2.circlepath"), children: models))
                }
                items += ChatPolishMenus.answerItems(turn: turn, store: store)
                return UIMenu(children: [UIMenu(title: AgentTurn.menuTimestamp(turn.endedAt ?? turn.promptAt), options: .displayInline, children: items)])
            }
            actions.hit = { hit in
                switch hit {
                case .copyAnswer: UIPasteboard.general.string = turn.answerMarkdown
                case .shareAnswer: ChatShare.present(turn.answerMarkdown)
                case .retry: store.retry(turn)
                default: break
                }
            }
            return
        case .thought, .toolGroup:
            actions.menu = { _ in nil }
        default:
            break
        }
        // A native line opens its disclosure through the transcript's hold and spring, as its
        // SwiftUI row's button does (`toggleDisclosure`): the tapped line stays where it is drawn,
        // and a chat following its newest row does not re-pin to it while the body opens.
        actions.hit = { hit in
            if case .toggle(let key) = hit { toggleDisclosure(context.foldHold, key: key, in: disclosures) { disclosures.set(key, true) } }
        }
    }

    /// The card's files that are marked viewed, by index.
    static func viewed(_ changes: DiffChangeSet) -> Set<Int> {
        Set(changes.files.indices.filter { DiffViewedStore.shared.isViewed(key: viewedKey(changes.files[$0], in: changes.id)) })
    }

    /// `DiffViewedStore.key(for:)`: the file's content hash is computed once per content
    /// (`DiffFile.contentHash`), so the key follows every change and needs no cache here.
    static func viewedKey(_ file: DiffFile, in changeSetID: String) -> String {
        DiffViewedStore.key(for: file)
    }
}

/// The chat polish rows of the prompt and answer menus: Bookmark (a prompt), Pin (an
/// answer) and Read Aloud, read when the menu opens.
@MainActor
enum ChatPolishMenus {
    static func promptItems(turnID: String, text: String, store: AgentChatStore) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if let turn = store.turns.first(where: { $0.id == turnID }), store.canBookmark(turn) {
            let marked = store.isBookmarked(turn)
            items.append(UIAction(title: marked ? String(localized: "Remove Bookmark") : String(localized: "Bookmark"),
                                  image: UIImage(systemName: marked ? "bookmark.slash" : "bookmark")) { _ in store.toggleBookmark(turn) })
        }
        items.append(readAloud(ChatReadAloud.id(chat: store.summary.id, turn: turnID, prompt: true), markdown: text))
        return items
    }

    static func answerItems(turn: AgentTurn, store: AgentChatStore) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        if store.canPin(turn) {
            let pinned = store.isPinned(turn)
            items.append(UIAction(title: pinned ? String(localized: "Unpin") : String(localized: "Pin"),
                                  image: UIImage(systemName: pinned ? "pin.slash" : "pin")) { _ in store.togglePin(turn) })
        }
        if !turn.answerMarkdown.isEmpty {
            items.append(readAloud(ChatReadAloud.id(chat: store.summary.id, turn: turn.id, prompt: false), markdown: turn.answerMarkdown))
        }
        return items
    }

    private static func readAloud(_ id: String, markdown: String) -> UIAction {
        let reading = ChatReadAloud.shared.isReading(id)
        return UIAction(title: reading ? String(localized: "Stop Reading") : String(localized: "Read Aloud"),
                        image: UIImage(systemName: reading ? "stop.circle" : "speaker.wave.2")) { _ in
            ChatReadAloud.shared.toggle(id, markdown: markdown)
        }
    }
}

/// The prompt's "Select Text" sheet: the whole text, selectable, at medium and large detents.
@MainActor
enum ChatSelectText {
    static func present(_ text: String) {
        SelectableTextView(text).present()
    }

    /// An answer's Markdown as the transcript reads it, for selecting: link and image
    /// targets, emphasis marks, inline-code ticks, heading and quote marks, code fences,
    /// rules and table rules go; lines, list items, code (verbatim) and table cells
    /// (tab-separated) stay.
    nonisolated static func readable(_ markdown: String) -> String {
        var out: [String] = []
        // An open code fence: its mark and length (CommonMark: a backtick fence's info string
        // holds no backtick, and only a run as long or longer, alone on its line, closes it).
        var fence: (mark: Character, count: Int)?
        var inTable = false
        let lines = markdown.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let mark = trimmed.first, mark == "`" || mark == "~" {
                let run = trimmed.prefix { $0 == mark }.count
                let rest = trimmed.dropFirst(run)
                if let open = fence {
                    if mark == open.mark, run >= open.count, rest.allSatisfy(\.isWhitespace) {
                        fence = nil
                        continue
                    }
                } else if run >= 3, !(mark == "`" && rest.contains("`")) {
                    fence = (mark, run)
                    continue
                }
            }
            if fence != nil {
                out.append(raw)
                continue
            }
            // A table: a header row followed by its delimiter row, then rows until a line
            // without a cell bar.
            if !inTable, trimmed.contains("|"), index + 1 < lines.count, Self.isTableRule(lines[index + 1]) { inTable = true }
            if inTable, !trimmed.contains("|") { inTable = false }
            if inTable {
                // The delimiter row (|---|:--:|) is the table's drawing, not its text.
                if Self.isTableRule(raw) { continue }
                out.append(Self.tableCells(trimmed).map(inline).joined(separator: "\t"))
                continue
            }
            // A thematic break (---, ***, * * *) is drawing too.
            let compact = trimmed.filter { $0 != " " }
            if compact.count >= 3, let mark = compact.first, "-*_".contains(mark), compact.allSatisfy({ $0 == mark }) { continue }
            out.append(inline(Self.blockMarks.apply(raw)))
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func tableCells(_ row: String) -> [String] {
        var cells = row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    /// A table's delimiter row: cells of dashes with optional alignment colons, at least one bar.
    nonisolated private static func isTableRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        let cells = tableCells(trimmed)
        return !cells.isEmpty && cells.allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { "-: ".contains($0) }
        }
    }

    /// Inline Markdown as read. Code spans keep their characters as written (`__init__`,
    /// `*.swift`); outside them `[text](url)` and `![alt](src)` keep their text and bold,
    /// strike and emphasis lose their marks (underscores only at word edges).
    nonisolated private static func inline(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`") {
            let ticks = rest[open...].prefix { $0 == "`" }
            let after = rest[ticks.endIndex...]
            guard let close = after.range(of: String(ticks)) else { break }
            result += inlineMarks.apply(String(rest[..<open]))
            result += after[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            rest = after[close.upperBound...]
        }
        return result + inlineMarks.apply(String(rest))
    }

    nonisolated private static let blockMarks = MarkdownRewrite([
        (#"^(\s*)#{1,6}\s+"#, "$1"),
        (#"^(\s*)>+\s?"#, "$1"),
        (#"^(\s*)[-*+]\s+\[[ xX]\]\s+"#, "$1• "),
        (#"^(\s*)[-*+]\s+"#, "$1• "),
    ])

    nonisolated private static let inlineMarks = MarkdownRewrite([
        (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),
        (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),
        (#"(\*\*|~~)(.+?)\1"#, "$2"),
        (#"(?<![\w])__(.+?)__(?![\w])"#, "$1"),
        (#"(^|[\s(])\*([^*\s][^*]*)\*"#, "$1$2"),
        (#"(?<![\w])_([^_\s][^_]*)_(?![\w])"#, "$1"),
    ])
}

/// Regular-expression rewrites compiled once, applied in order. Shared read-only:
/// NSRegularExpression is immutable and documented safe to use from any thread.
struct MarkdownRewrite: @unchecked Sendable {
    private let rules: [(NSRegularExpression, String)]

    init(_ rules: [(String, String)]) {
        self.rules = rules.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])).map { ($0, template) }
        }
    }

    func apply(_ text: String) -> String {
        rules.reduce(text) { text, rule in
            rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
        }
    }
}
#endif
