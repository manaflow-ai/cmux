import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// A size change that reaches Home with no layout pass of its own (a superview
/// autoresize, an NSSplitView moving its divider) still reaches the transcript:
/// my bubbles sit at the right edge of the width they were laid out for, so a
/// transcript left at the old, wider width drew them past the pane's right edge
/// (Lawrence 2026-10-19: "crash analytics set up", "You should always r" cut off).
@MainActor @Suite(.serialized) struct HomeResizeFollowTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")
    static let long = "Fix all. Make sure that we have proper Sentry crash analytics set up so everything is observable to us. "
        + "Can you check Sentry CLI to see if there are any crashes there that you can fix?"

    /// Home in an offscreen window at 900 pt, a long message of mine loaded.
    private func home() -> (NSWindow, MessagesLabHomeView) {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            TranscriptItem(key: IdempotencyKey("k1"), seq: 1, author: Self.them, parts: [.text("Started a99.")],
                           createdAt: base, delivery: .committed, messageID: MessageID("msg_1")),
            TranscriptItem(key: IdempotencyKey("k2"), seq: 2, author: Self.me, parts: [.text(Self.long)],
                           createdAt: base.addingTimeInterval(1), delivery: .committed, messageID: MessageID("msg_2")),
        ]
        let id = ConversationID("conv_resize")
        let summary = ConversationSummary(id: id, title: "Chief", participants: people, lastSeq: 2,
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        let view = MessagesLabHomeView(store: store, conversation: id, me: Self.me, wake: NoWake())
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(id, items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        view.controller.install(conv, windowStart: w.start, total: w.total)
        container.layoutSubtreeIfNeeded()
        return (window, view)
    }

    /// The rows of my messages: the width they were laid out for and their bubble's right edge.
    private func mine(_ view: MessagesLabHomeView) -> [(width: CGFloat, right: CGFloat)] {
        guard let demo = view.controller.demo else { return [] }
        return demo.model.rows.compactMap { row in
            guard case let .part(p) = row.spec.kind, p.outgoing else { return nil }
            return (row.spec.width, row.spec.metrics.rightEdge)
        }
    }

    @Test(arguments: [480.0, 620.0, 1200.0])
    func aSizeChangeWithoutALayoutRequestReachesTheTranscript(width: Double) throws {
        let (window, view) = home()
        defer { window.close() }
        #expect(view.controller.host.frame.width == 900)
        #expect(!mine(view).isEmpty)

        // What an autoresize or a split view divider does: the frame only.
        view.setFrameSize(NSSize(width: width, height: 700))
        // What AppKit does before the next display.
        window.contentView?.layoutSubtreeIfNeeded()

        let w = CGFloat(width)
        #expect(view.controller.host.frame.width == w)
        let demo = try #require(view.controller.demo)
        #expect(demo.bounds.width == w)
        for row in mine(view) {
            #expect(row.width == w, "my row was laid out for \(row.width) pt in a \(w) pt pane")
            #expect(row.right <= w, "my bubble ends at \(row.right) pt, past the pane's \(w) pt")
        }
    }
}
