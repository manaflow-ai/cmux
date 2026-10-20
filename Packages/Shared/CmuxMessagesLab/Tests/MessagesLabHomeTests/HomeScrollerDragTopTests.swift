import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// Dragging the scroller's knob to the top of a long Home transcript shows the
/// oldest loaded message, and the transcript stays there after the release.
/// Lawrence 2026-10-19 (scrawl 37, cmux NIGHTLY 4803cf8): "I can't scroll up all
/// the way… I can just drag it up. It's empty up here. I have to let go. It jumps
/// all the way back down here." The knob mapped its value over the document's
/// height from y = 0, but the document starts at the layout's slack (about
/// 6000 pt of empty space above the oldest row), so the knob scrolled into the
/// empty slack.
@MainActor @Suite(.serialized) struct HomeScrollerDragTopTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let me = ParticipantID("user_me")
    static let them = ParticipantID("agent_chief")

    /// Home in an offscreen window, `count` messages loaded (all of the history).
    private func home(count: Int = 160) -> (NSWindow, MessagesLabHomeView) {
        let people = [CmuxHomeCore.Participant(id: Self.me, kind: .human, displayName: "Me"),
                      CmuxHomeCore.Participant(id: Self.them, kind: .agent, displayName: "Chief", agentClass: .chief)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let items = (1...count).map { i in
            TranscriptItem(key: IdempotencyKey("k\(i)"), seq: UInt64(i), author: i % 3 == 0 ? Self.me : Self.them,
                           parts: [.text("Message \(i): " + String(repeating: "a few words of text ", count: 1 + i % 7))],
                           createdAt: base.addingTimeInterval(TimeInterval(i)), delivery: .committed,
                           messageID: MessageID("msg_\(i)"))
        }
        let id = ConversationID("conv_scroll_top")
        let summary = ConversationSummary(id: id, title: "Chief", participants: people, lastSeq: UInt64(count),
                                          createdAt: base, updatedAt: base, readCursors: [:], readCursorTimes: [:])
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        let view = MessagesLabHomeView(store: store, conversation: id, me: Self.me, wake: NoWake())
        var core = ProjectionCore(me: Self.me)
        let (conv, w) = core.install(id, items: items, summary: summary)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        view.controller.install(conv, windowStart: w.start, total: w.total)
        container.layoutSubtreeIfNeeded()
        return (window, view)
    }

    /// Visible rows of the transcript (cells on screen with a row).
    private func visibleRows(_ demo: MessagesWindowView) -> [Int] {
        demo.collection.visibleCells.compactMap { demo.collection.indexPath(for: $0)?.item }.filter { $0 < demo.model.count }
    }

    @Test func draggingTheKnobToTheTopShowsTheOldestMessageAndStaysThere() throws {
        let (window, view) = home()
        defer { window.close() }
        let demo = try #require(view.controller.demo)
        let scroller = try #require(view.controller.host.scrollView.verticalScroller as? SequenceScroller)
        #expect(demo.pinnedOffset - demo.minOffset > 2000, "the transcript must be several screens long")
        #expect(demo.layout.rowsTop > 1000, "the layout keeps its slack above the oldest row")

        // A knob drag to the top of the track (the pointer far above clamps the knob at 0).
        scroller.dragBegan(at: 0, grab: 0)
        scroller.dragMoved(to: -100_000)
        window.contentView?.layoutSubtreeIfNeeded()
        demo.collection.layoutIfNeeded()

        let y = demo.collection.contentOffset.y
        #expect(abs(y - demo.minOffset) <= 1, "knob at the top: offset \(y), the top is \(demo.minOffset)")
        #expect(demo.firstVisibleRow == 0)
        #expect(visibleRows(demo).contains(0), "the oldest message shows while the knob is held at the top")

        // Release: the transcript stays at the top.
        scroller.dragEnded()
        window.contentView?.layoutSubtreeIfNeeded()
        demo.collection.layoutIfNeeded()
        #expect(abs(demo.collection.contentOffset.y - demo.minOffset) <= 1,
                "after the release the offset moved to \(demo.collection.contentOffset.y)")
        #expect(!view.controller.store!.state.ui.scroll.pinnedToBottom)
        #expect(visibleRows(demo).contains(0))
    }

    @Test(arguments: [0.25, 0.5, 0.75])
    func aKnobDragAlwaysShowsMessages(value: Double) throws {
        let (window, view) = home()
        defer { window.close() }
        let demo = try #require(view.controller.demo)
        let scroller = try #require(view.controller.host.scrollView.verticalScroller as? SequenceScroller)

        scroller.dragBegan(at: 0, grab: 0)
        scroller.onJump(value)
        window.contentView?.layoutSubtreeIfNeeded()
        demo.collection.layoutIfNeeded()

        let y = demo.collection.contentOffset.y
        #expect(y >= demo.minOffset - 1 && y <= demo.pinnedOffset + 1,
                "offset \(y) outside the transcript \(demo.minOffset)...\(demo.pinnedOffset)")
        #expect(!visibleRows(demo).isEmpty, "the knob at \(value) shows no message")
        scroller.dragEnded()
    }
}
