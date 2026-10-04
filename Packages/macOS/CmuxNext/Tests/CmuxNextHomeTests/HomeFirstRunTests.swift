import AppKit
import CmuxHomeCore
import Testing
@testable import CmuxNextHome

/// An empty Chief conversation says what the Chief is and offers one
/// suggested prompt (Leo's dogfood: "an empty pane with an M avatar, a Home
/// label and a Message box"). The suggestion fills the field; it never
/// sends. The first message hides the panel. The transcript is
/// MessagesLab's (`MessagesLabHome`); this view only adds the panel.
@MainActor
@Suite(.serialized) struct HomeFirstRunTests {
    static let me = ParticipantID("user_me")
    static let chief = ParticipantID("agent_mux")
    static let id = ConversationID("conv_first_run")
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func summary(lastSeq: Seq = 0) -> ConversationSummary {
        ConversationSummary(id: id, participants: [Participant(id: me, kind: .human, displayName: "Me"),
                                                   Participant(id: chief, kind: .agent, displayName: "Chief", agentClass: .chief)],
                            lastSeq: lastSeq, createdAt: start, updatedAt: start, readCursors: [:])
    }

    static func view(messages: [Message] = []) async -> (NSWindow, HomeNativeTranscriptView, HomeStore) {
        let source = FirstRunSource(me: Participant(id: me, kind: .human, displayName: "Me"),
                                    summary: summary(lastSeq: Seq(messages.count)), messages: messages)
        let store = HomeStore(source: source)
        store.start()
        for _ in 0..<400 where !(store.isOnline && store.me != nil) { try? await Task.sleep(for: .milliseconds(5)) }
        await store.open(id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: me)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (window, view, store)
    }

    @Test func anEmptyChiefConversationExplainsTheChiefAndSuggestsAPrompt() async throws {
        let (window, view, store) = await Self.view()
        defer { view.stop(); store.stop(); window.close() }
        let panel = view.firstRun
        #expect(!panel.isHidden)
        #expect(!panel.title.stringValue.isEmpty)
        #expect(!panel.suggestion.title.isEmpty)
        let field = try #require(view.primaryInput as? NSTextView)
        #expect(field.string.isEmpty)
        panel.suggestion.performClick(nil)
        #expect(field.string == panel.suggestion.title, "the suggestion fills the field")
        // Text on glass, never a control that dims to gray when the window is not key.
        #expect(panel.suggestion.label.textColor == panel.title.textColor)
        #expect(panel.suggestion.accessibilityRole() == .button)
    }

    @Test func theFirstMessageHidesThePanel() async {
        let message = Message(id: MessageID("msg_1"), conversation: Self.id, seq: Seq(1), clientMessageID: IdempotencyKey("k1"),
                              author: Self.chief, parts: [.text("Hello")], createdAt: Self.start)
        let (window, view, store) = await Self.view(messages: [message])
        defer { view.stop(); store.stop(); window.close() }
        view.layoutSubtreeIfNeeded()
        #expect(view.firstRun.isHidden)
    }
}

/// One conversation, answered from memory.
actor FirstRunSource: HomeSource {
    let me: Participant
    let summary: ConversationSummary
    let messages: [Message]

    init(me: Participant, summary: ConversationSummary, messages: [Message]) {
        self.me = me
        self.summary = summary
        self.messages = messages
    }

    func events() -> AsyncStream<HomeEvent> {
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream()
        continuation.yield(.connection(.online))
        continuation.yield(.inbox(InboxSnapshot(me: me, conversations: [summary], rev: 1)))
        return stream
    }

    func inbox() -> InboxSnapshot { InboxSnapshot(me: me, conversations: [summary], rev: 1) }
    func snapshot(of conversation: ConversationID, tail: Int) -> ConversationPage {
        ConversationPage(conversation: summary, messages: messages)
    }
    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) -> [Message] { [] }
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult { HomeOpResult(rev: 2) }
    func search(_ query: String, limit: Int) -> [HomeSearchHit] { [] }
    func resolve(_ contact: ContactAddress) -> ContactResolution { .invitable(contact) }
}
