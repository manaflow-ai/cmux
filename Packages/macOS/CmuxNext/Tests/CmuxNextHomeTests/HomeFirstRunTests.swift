import AppKit
import CmuxHomeCore
import Testing
@testable import CmuxNextHome

/// An empty Chief conversation offers things to do now instead of a pitch
/// (Leo's first-launch capture, op-next-look): rows to open a terminal,
/// start an agent or ask the Chief, and a keyboard hint. The
/// ask row fills the field; it never sends. The first message hides the
/// panel. The transcript is MessagesLab's (`MessagesLabHome`); this view
/// only adds the panel.
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 628, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: me)
        await view.binding.opened()
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (window, view, store)
    }

    @Test func theAskRowFillsTheFieldAndNeverSends() async throws {
        let (window, view, store) = await Self.view()
        defer { view.stop(); store.stop(); window.close() }
        let panel = view.firstRun
        #expect(!panel.isHidden)
        #expect(!panel.suggestion.title.isEmpty)
        let field = try #require(view.primaryInput as? NSTextView)
        #expect(field.string.isEmpty)
        panel.suggestion.performClick(nil)
        #expect(field.string == panel.suggestion.title, "the suggestion fills the field")
        // Never a control that dims to gray when the window is not key.
        #expect(panel.suggestion.label.textColor == panel.terminal.label.textColor)
        #expect(panel.rows.allSatisfy { $0.accessibilityRole() == .button })
    }

    @Test func theTerminalAndAgentRowsAskTheHost() async throws {
        let (window, view, store) = await Self.view()
        defer { view.stop(); store.stop(); window.close() }
        var picked: [HomeFirstRunAction] = []
        view.onFirstRunAction = { picked.append($0) }
        view.firstRun.terminal.performClick(nil)
        view.firstRun.agent.performClick(nil)
        #expect(picked == [.openTerminal, .startAgent])
        let field = try #require(view.primaryInput as? NSTextView)
        #expect(field.string.isEmpty, "neither row types into the field")
    }

    @Test func theRowsShowTheirShortcutsAndTheTabHintShowsItsKeys() async {
        let (window, view, store) = await Self.view()
        defer { view.stop(); store.stop(); window.close() }
        let panel = view.firstRun
        #expect(panel.hint.isHidden, "no hint until the host passes the keys")
        view.setFirstRunShortcuts(terminal: "⌘T", agent: nil, tabs: "⌃1…9")
        view.layoutSubtreeIfNeeded()
        #expect(panel.terminal.shortcutLabel.stringValue == "⌘T" && !panel.terminal.shortcutLabel.isHidden)
        #expect(panel.agent.shortcutLabel.isHidden, "an unbound action shows no shortcut")
        #expect(!panel.hint.isHidden && panel.hint.stringValue.contains("⌃1…9"))
        let row = panel.terminal
        #expect(row.label.frame.maxX <= row.shortcutLabel.frame.minX, "label \(row.label.frame) runs into the shortcut")
    }

    /// Leo, 2026-10-06: labels and actions only. "Chief runs your agents on
    /// this Mac", "Ask Chief below" and "This Chief remembers on this device
    /// only" explained the app; the panel shows its rows and the shortcut
    /// hint, no other text.
    @Test func thePanelHasNoProseBesideItsRows() async {
        let (window, view, store) = await Self.view()
        defer { view.stop(); store.stop(); window.close() }
        view.setFirstRunShortcuts(terminal: "⌘T", agent: nil, tabs: "⌃1…9")
        view.layoutSubtreeIfNeeded()
        let panel = view.firstRun
        func labels(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { sub -> [NSTextField] in
                if sub is HomeFirstRunRow { return [] }
                return ((sub as? NSTextField).map { [$0] } ?? []) + labels(in: sub)
            }
        }
        let shown = labels(in: panel).filter { !$0.isHidden && !$0.stringValue.isEmpty }.map(\.stringValue)
        #expect(shown == [panel.hint.stringValue], "text outside the rows: \(shown)")
    }

    @Test func firstRunChromeFollowsTheLiveInterfaceScale() async {
        let (window, view, store) = await Self.view()
        defer { view.stop(); store.stop(); window.close() }
        view.layoutSubtreeIfNeeded()
        let panel = view.firstRun
        let baseHeight = panel.terminal.bounds.height
        let baseFontSize = panel.hint.font?.pointSize ?? 0

        view.applyTextScale(1.25)
        view.layoutSubtreeIfNeeded()

        #expect(panel.terminal.bounds.height > baseHeight)
        #expect(panel.hint.font?.pointSize ?? 0 > baseFontSize)
    }

    /// Stability rule: a Chief conversation whose history is still loading
    /// is empty for a moment; the panel waits for the first page instead of
    /// flashing in and out.
    @Test func aHeldPanelWaitsForTheFirstPage() async {
        let (window, view, store) = await Self.view()
        defer { view.stop(); store.stop(); window.close() }
        view.holdsFirstRun = true
        view.layoutSubtreeIfNeeded()
        #expect(view.firstRun.isHidden)
        view.holdsFirstRun = false
        #expect(!view.firstRun.isHidden)
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
