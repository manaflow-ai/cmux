public import CmuxHomeCore
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// The started-agent pills of the Messages page's open Chief chat and their agent pane, as the native
/// transcript had them (user 2026-11-03: one pill per agent, a click opens its chat). The store's
/// transcript has each turn's agents row (``HomeAgentMessageRow/Kind/fold(count:peers:expanded:)``);
/// this host sends them on the `agents` stream with the agents' chats:
/// `{conversation, rows: [{after, group, peers, titles, states, unread}], threads: [{peer, title, state,
/// task?, entries: [{id, sender, text}], startedAt, endedAt?, workspaceLink?}]}` (times in epoch ms;
/// `after`: the message the row follows, null before the first one), or null while no Chief chat shows.
/// The pane's ops: `agents.seen {conversation, peer}` (its unread dot clears) and
/// `agents.note {conversation, peer, text}` (the person's words to the agent, through the Chief).
///
/// The store loads a conversation's agent runs only while a view has it open, so this host holds the
/// shown Chief chat open in the store (``show(_:)``), and only that one: the cost is one conversation's
/// window, whatever the number of chats.
@MainActor
public final class HomePageAgents {
    /// The page's updates (followed through Observation while the page listens).
    private lazy var stream = HomePageStream(observing: { [weak self] in self?.payload() ?? .null })
    private let store: @MainActor () -> HomeStore?
    /// The conversation the page shows, as it last said.
    private var shown: ConversationID?
    /// The page's listeners: the chat is held only while one listens, so a closed page lets it go.
    private var listeners = 0
    /// The Chief chat this host holds open in the store.
    private(set) var held: ConversationID?

    public init(store: @escaping @MainActor () -> HomeStore?) {
        self.store = store
    }

    /// The page shows `conversation` (nil: none).
    public func show(_ conversation: ConversationID?) {
        shown = conversation
        hold()
    }

    /// A page listener of the `agents` stream: it gets the value now and each change.
    public func subscribe(_ onEvent: @escaping @MainActor (JSONValue) -> Void) -> PageSubscription {
        listeners += 1
        hold()
        let inner = stream.subscribe(onEvent)
        return PageSubscription { [weak self] in
            inner.cancel()
            guard let self else { return }
            listeners -= 1
            hold()
        }
    }

    /// Holds the shown chat open in the store while it is a Chief's and the page listens, letting go of
    /// the one before; the stream reads again on a change.
    private func hold() {
        let store = store()
        let chief = listeners > 0 && shown.flatMap({ id in store?.rows.first { $0.id == id } })?.kind == .chief ? shown : nil
        guard chief != held else { return }
        if let held { store?.close(held) }
        held = chief
        if let chief { store?.beginOpen(chief) }
        stream.restart()
    }

    /// One `agents.*` call; `name` without the page prefix. A note is the person's only.
    public func call(_ name: String, _ params: JSONValue, userGesture: Bool, personOnly: String) async throws -> JSONValue {
        guard let store = store(), let conversation = params["conversation"]?.stringValue.map({ ConversationID($0) }),
              conversation == held else { throw PageError.invalidParams("conversation must be the shown Chief chat") }
        guard let peer = params["peer"]?.stringValue, !peer.isEmpty else { throw PageError.invalidParams("peer must name an agent") }
        switch name {
        case "agents.seen":
            store.markAgentSeen(peer, in: conversation)
        case "agents.note":
            guard userGesture else { throw PageError(code: PageNativeOp.userOnlyCode, message: personOnly) }
            try await store.sendAgentNote(params["text"]?.stringValue ?? "", to: peer, in: conversation)
        default:
            throw PageError.unknownOp(name)
        }
        return .null
    }

    /// The shown Chief chat's agents rows and chats; null while none shows.
    func payload() -> JSONValue {
        guard let held, let store = store() else { return .null }
        return Self.payload(held, items: store.transcript(for: held)) { store.agentThread($0, in: held) }
    }

    /// `conversation`'s agents rows in `items` (its transcript), each after the message it follows, and
    /// the chats of their agents (`thread`), each once.
    static func payload(_ conversation: ConversationID, items: [TranscriptItem], thread: (String) -> HomeAgentThread?) -> JSONValue {
        var rows: [JSONValue] = []
        var peers: [String] = []
        var seen: Set<String> = []
        var after: MessageID?
        for item in items {
            guard let row = item.agentMessage else {
                after = item.messageID ?? after
                continue
            }
            guard case .fold(_, let names, _) = row.kind else { continue }
            rows.append(.object([
                "after": after.map { .string($0.rawValue) } ?? .null,
                "group": .string(row.group),
                "peers": .array(names.map(JSONValue.string)),
                "titles": .array(row.peerTitles.map(JSONValue.string)),
                "states": .array(row.peerStates.map { .string(word($0)) }),
                "unread": .array(row.peerUnread.map(JSONValue.bool)),
            ]))
            for name in names where seen.insert(name).inserted { peers.append(name) }
        }
        let threads = peers.compactMap { thread($0).map(page) }
        return .object(["conversation": .string(conversation.rawValue), "rows": .array(rows), "threads": .array(threads)])
    }

    /// A chat as the page reads it (agentModel.ts `AgentThread`).
    static func page(_ thread: HomeAgentThread) -> JSONValue {
        var fields: [String: JSONValue] = [
            "peer": .string(thread.peer), "title": .string(thread.title), "state": .string(word(thread.state)),
            "entries": .array(thread.entries.map { entry in
                .object(["id": .string(entry.id), "sender": .string(word(entry.sender)), "text": .string(entry.text)])
            }),
            "startedAt": .number(milliseconds(thread.startedAt)),
        ]
        if let task = thread.task { fields["task"] = .string(task) }
        if let ended = thread.endedAt { fields["endedAt"] = .number(milliseconds(ended)) }
        if let link = thread.workspaceLink { fields["workspaceLink"] = .string(link.absoluteString) }
        return .object(fields)
    }

    static func word(_ state: HomeAgentMessageRow.PeerState) -> String {
        switch state {
        case .queued: "queued"
        case .told: "told"
        case .reported: "reported"
        case .stopped: "stopped"
        }
    }

    static func word(_ sender: HomeAgentSender) -> String {
        switch sender {
        case .agent: "agent"
        case .chief: "chief"
        case .you: "you"
        }
    }

    private static func milliseconds(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
}
