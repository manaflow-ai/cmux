import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// u9489 (Oct 21): "After I right-click an index.html document thing and then use 'Send a message',
/// the darker area does not shift properly." The right-clicked bubble's highlight (the darker
/// area) must stay on its bubble while the transcript moves under it: a message sent or received,
/// a scroll, a pane resize. It was drawn once in the transcript view's coordinates, so it stayed
/// where the bubble had been.
@MainActor @Suite(.serialized) struct HomeMenuHighlightFollowTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")
    static let mine = "Here is the page: index.html"

    private func home() -> (NSWindow, MessagesLabHomeView) {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            TranscriptItem(key: IdempotencyKey("k1"), seq: 1, author: Self.them, parts: [.text("Send me the page.")],
                           createdAt: base, delivery: .committed, messageID: MessageID("msg_1")),
            TranscriptItem(key: IdempotencyKey("k2"), seq: 2, author: Self.me, parts: [.text(Self.mine)],
                           createdAt: base.addingTimeInterval(1), delivery: .committed, messageID: MessageID("msg_2")),
        ]
        let id = ConversationID("conv_highlight")
        let summary = ConversationSummary(id: id, title: "Chief", participants: people, lastSeq: 2,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        let view = MessagesLabHomeView(store: store, conversation: id, me: Self.me, wake: NoWake())
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(id, items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        view.controller.install(conv, windowStart: w.start, total: w.total)
        container.layoutSubtreeIfNeeded()
        return (window, view)
    }

    /// The highlight's box in the transcript view's coordinates (where `debugBubble` measures), wherever its layer lives.
    private func highlightBox(_ view: MessagesLabHomeView) -> CGRect? {
        guard let hl = view.controller.menuHighlight, let space = view.controller.demo?.layer else { return nil }
        let layer = hl.layer
        let local = (layer as? CAShapeLayer)?.path?.boundingBoxOfPath ?? layer.bounds
        return layer.convert(local, to: space)
    }

    @Test func theHighlightStaysOnItsBubbleWhenTheTranscriptMoves() throws {
        let (window, view) = home()
        defer { window.close() }
        let before = try #require(view.debugBubble(text: Self.mine))
        _ = try #require(view.controller.menu(at: CGPoint(x: before.body.midX, y: before.body.midY)))
        defer { view.controller.menuHighlight?.discard() }
        let shown = try #require(highlightBox(view))
        #expect(abs(shown.midY - before.outline.midY) < 4, "the highlight starts off its bubble: \(shown) vs \(before.outline)")
        // The pane gets shorter: the bottom-anchored rows move up in the transcript view.
        view.frame.size.height = 420
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        let after = try #require(view.debugBubble(text: Self.mine))
        try #require(abs(after.outline.midY - before.outline.midY) > 20, "the bubble did not move; the test proves nothing")
        let moved = try #require(highlightBox(view))
        #expect(abs(moved.midY - after.outline.midY) < 4,
                "the highlight stayed where the bubble was: highlight \(moved), bubble \(after.outline) (was \(before.outline))")
        #expect(abs(moved.midX - after.outline.midX) < 4)
    }
}
