import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// u5402 (Oct 20): a right-click on a Home bubble gives Forward…, which hands the bubble's text to
/// the host (cmux-next's Send To…, which asks for the chat or agent). Without a host route the row
/// is not offered. The menu is built and chosen through the right-click's path (`menu(at:)`).
/// Reply… and Try Again are the menu's own rows, covered by their tests.
@MainActor @Suite(.serialized) struct HomeForwardMenuTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")
    static let reply = "The build is green on cmux9s."

    private func home() -> (NSWindow, MessagesLabHomeView) {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            TranscriptItem(key: IdempotencyKey("k1"), seq: 1, author: Self.me, parts: [.text("Is it green?")],
                           createdAt: base, delivery: .committed, messageID: MessageID("msg_1")),
            TranscriptItem(key: IdempotencyKey("k2"), seq: 2, author: Self.them, parts: [.text(Self.reply)],
                           createdAt: base.addingTimeInterval(1), delivery: .committed, messageID: MessageID("msg_2")),
        ]
        let id = ConversationID("conv_forward")
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

    @Test func forwardHandsTheBubblesTextToTheHost() {
        let (window, view) = home()
        defer { window.close() }
        var forwarded: [String] = []
        view.onForward = { forwarded.append($0) }
        #expect(view.debugChooseMenuItem(MessagesLabHomeView.forwardMenuTitle, onBubble: Self.reply))
        #expect(forwarded == [Self.reply])
        #expect(view.debugChooseMenuItem(MessagesLabHomeView.forwardMenuTitle, onBubble: "Is it green?"))
        #expect(forwarded == [Self.reply, "Is it green?"])
    }

    @Test func withoutAHostRouteThereIsNoForward() {
        let (window, view) = home()
        defer { window.close() }
        view.onForward = nil
        #expect(!view.debugChooseMenuItem(MessagesLabHomeView.forwardMenuTitle, onBubble: Self.reply))
    }
}
