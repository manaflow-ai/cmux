import AppKit
import CmuxHomeCore
import Foundation
@testable import MessagesLabHome

/// A conversation owner for tests: one conversation, events on demand,
/// every submitted intent recorded. `submit` answers (or refuses) but commits
/// nothing; a test publishes the owner's message events itself.
actor ScriptedSource: HomeSource {
    let me: CmuxHomeCore.Participant
    var summary: ConversationSummary
    var messages: [CmuxHomeCore.Message]
    private var continuation: AsyncStream<HomeEvent>.Continuation?
    private(set) var submitted: [HomeIntent] = []
    var refusal: HomeRejection?
    private var rev: Revision = 10

    init(me: CmuxHomeCore.Participant, summary: ConversationSummary, messages: [CmuxHomeCore.Message]) {
        self.me = me
        self.summary = summary
        self.messages = messages
    }

    func events() -> AsyncStream<HomeEvent> {
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        continuation.yield(.connection(.online))
        continuation.yield(.inbox(InboxSnapshot(me: me, conversations: [summary], rev: 1)))
        return stream
    }

    func inbox() -> InboxSnapshot { InboxSnapshot(me: me, conversations: [summary], rev: 1) }

    func snapshot(of conversation: ConversationID, tail: Int) -> ConversationPage {
        ConversationPage(conversation: summary, messages: Array(messages.suffix(tail)))
    }

    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) -> [CmuxHomeCore.Message] {
        Array(messages.filter { $0.seq < beforeSeq }.suffix(limit))
    }

    func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        submitted.append(intent)
        if let refusal { throw refusal }
        rev += 1
        return HomeOpResult(rev: rev)
    }

    func search(_ query: String, limit: Int) -> [HomeSearchHit] { [] }
    func resolve(_ contact: ContactAddress) -> ContactResolution { .invitable(contact) }

    func setRefusal(_ r: HomeRejection?) { refusal = r }
    func publish(_ event: HomeEvent) { continuation?.yield(event) }
}

enum Fixture2 {
    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")
    static let id = ConversationID("conv_test")
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static var people: [CmuxHomeCore.Participant] {
        [CmuxHomeCore.Participant(id: me, kind: .human, displayName: "Me"),
         CmuxHomeCore.Participant(id: them, kind: .agent, displayName: "Chief", agentClass: .chief)]
    }

    static func summary(lastSeq: Seq = 0, read: Seq? = nil) -> ConversationSummary {
        ConversationSummary(id: id, title: "Chief", participants: people, lastSeq: lastSeq, createdAt: start, updatedAt: start,
                            readCursors: read.map { [them: $0] } ?? [:],
                            readCursorTimes: read.map { _ in [them: start.addingTimeInterval(500)] } ?? [:])
    }

    static func message(_ seq: Seq, _ author: ParticipantID, _ text: String, key: String? = nil) -> CmuxHomeCore.Message {
        CmuxHomeCore.Message(id: MessageID("msg_\(seq)"), conversation: id, seq: seq, clientMessageID: IdempotencyKey(key ?? "k\(seq)"),
                             author: author, parts: [.text(text)], createdAt: start.addingTimeInterval(Double(seq) * 30))
    }

    static func item(_ seq: Seq, _ author: ParticipantID, _ text: String, key: String? = nil) -> TranscriptItem {
        TranscriptItem(key: IdempotencyKey(key ?? "k\(seq)"), seq: seq, author: author, parts: [.text(text)],
                       createdAt: start.addingTimeInterval(Double(seq) * 30), delivery: .committed, messageID: MessageID("msg_\(seq)"))
    }

    static func history(_ n: Int) -> [TranscriptItem] {
        (1...n).map { item(Seq($0), $0 % 3 == 0 ? me : them, "Message number \($0) with a little text") }
    }

    /// A projection over a pane-sized host, not in a window.
    @MainActor
    static func projection(store: HomeStore? = nil) -> (HomeProjection, ChatController) {
        let controller = ChatController(host: HostView(frame: NSRect(x: 0, y: 0, width: 628, height: 900)), wake: NoWake())
        let store = store ?? HomeStore(source: ScriptedSource(me: people[0], summary: summary(), messages: []))
        let p = HomeProjection(store: store, conversation: id, me: me, controller: controller)
        return (p, controller)
    }
}

final class NoWake: ChatWakeScheduler {
    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
    func cancel() {}
}

@MainActor
func waitUntil(_ what: String = "", _ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}
