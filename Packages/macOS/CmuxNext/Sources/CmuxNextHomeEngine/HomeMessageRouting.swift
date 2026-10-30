public import CmuxHomeCore
public import CmuxNextHome
import Foundation

/// The one path every "Send Message…" entry point takes into the Home chat
/// (plans/cmux-next/home-chat-pipeline-DESIGN.md: it never orders or streams anything itself).
/// A right-click on a workspace, a tab or a Home row, "Send to Chief" and "Send To…" on selected
/// text, Forward… on a bubble, Cmd+Shift+P, `cmux chat send` and MCP all resolve their recipient
/// here, then either put text in that conversation's message box (``compose(_:into:)``) or send
/// it through ``HomeGroupActions/send(_:to:)``, the same send the message box makes.
///
/// ```swift
/// let routing = HomeMessageRouting(store: store, actions: actions, chief: { ConversationID("conv_chief") })
/// if let id = routing.resolve("Austin") { _ = routing.compose(HomeMessageRouting.quoted(selection), into: id) }
/// ```
@MainActor
public struct HomeMessageRouting: Sendable {
    private let store: HomeStore
    private let actions: HomeGroupActions
    private let chief: @MainActor @Sendable () -> ConversationID?
    private let chiefNames: @MainActor @Sendable () -> [ConversationID: String]

    /// - Parameters:
    ///   - store: The app's HomeStore (the single writer of drafts and sends).
    ///   - actions: The group actions; their `send` is the one send path.
    ///   - chief: The conversation with the user's Chief (Home's default conversation), if any.
    ///   - chiefNames: Each Chief's own name by its conversation (the app's `HomeChiefNames`), the
    ///     one its tile and header show; a conversation not in it goes by its row title.
    public init(store: HomeStore, actions: HomeGroupActions, chief: @escaping @MainActor @Sendable () -> ConversationID?,
                chiefNames: @escaping @MainActor @Sendable () -> [ConversationID: String] = { [:] }) {
        self.store = store
        self.actions = actions
        self.chief = chief
        self.chiefNames = chiefNames
    }

    /// `row`'s name: its Chief's own name, else its title.
    private func title(of row: InboxRow, names: [ConversationID: String]) -> String { names[row.id] ?? row.title }

    /// The Chief's conversation: the app's choice, else the first Chief conversation listed.
    public var chiefConversation: ConversationID? {
        if let id = chief(), store.rows.contains(where: { $0.id == id }) { return id }
        return store.rows.orderedForInbox().first { $0.kind == .chief }?.id
    }

    /// Every conversation a message can go to, as the palette and `--to` list them: Chiefs first,
    /// then the rest in inbox order. `value` is the conversation id, `title` its row title.
    public func recipients() -> [(value: String, title: String)] {
        let ordered = store.rows.orderedForInbox()
        let chiefs = ordered.filter { $0.kind == .chief }, others = ordered.filter { $0.kind != .chief }
        let names = chiefNames()
        return (chiefs + others).map { row in
            let title = title(of: row, names: names)
            return (value: row.id.rawValue, title: title.isEmpty ? row.id.rawValue : title)
        }
    }

    /// The conversation `text` names: a conversation id; `chief` (any case) for the Chief's; a
    /// participant's id or name in a one-to-one conversation; a row title (any case). Nil when
    /// nothing matches.
    public func resolve(_ text: String) -> ConversationID? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let rows = store.rows.orderedForInbox()
        if let row = rows.first(where: { $0.id.rawValue == name }) { return row.id }
        if name.caseInsensitiveCompare("chief") == .orderedSame { return chiefConversation }
        let me = store.me?.id
        let oneToOne = rows.filter { $0.kind != .group }
        if let row = oneToOne.first(where: { $0.summary.participants.contains { $0.id != me && $0.id.rawValue == name } }) { return row.id }
        if let row = oneToOne.first(where: { row in
            row.summary.participants.contains { $0.id != me && !$0.visibleName.isEmpty && $0.visibleName.caseInsensitiveCompare(name) == .orderedSame }
        }) { return row.id }
        let names = chiefNames()
        return rows.first { row in
            let title = title(of: row, names: names)
            return !title.isEmpty && title.caseInsensitiveCompare(name) == .orderedSame
        }?.id
    }

    /// Puts `text` in `id`'s message box after what is already there (a new line between), so
    /// nothing the person typed is lost. Returns the whole draft; nil when `id` is not listed.
    @discardableResult
    public func compose(_ text: String, into id: ConversationID) -> String? {
        guard store.rows.contains(where: { $0.id == id }) else { return nil }
        let own = store.draft(for: id) ?? ""
        let added = String(text.drop { $0.isNewline })
        let draft = own.isEmpty || own.hasSuffix("\n") ? own + added : own + "\n" + added
        store.setDraft(draft, for: id)
        return draft
    }

    /// Sends `text` to `id` as me, through the message box's own send (`HomeGroupActions.send`).
    public func send(_ text: String, to id: ConversationID) async -> HomeGroupOutcome {
        await actions.send(text, to: id)
    }

    /// Selected text as a Markdown quote ("> " before each line), then an empty line for the
    /// person's own words.
    public static func quoted(_ text: String) -> String {
        let lines = text.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        return lines.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n") + "\n\n"
    }

    /// A workspace or tab named in a message: a Markdown link Home shows as a link chip, then a space.
    public static func mention(_ title: String, link: String) -> String {
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "[\(label.isEmpty ? link : label)](\(link)) "
    }
}
