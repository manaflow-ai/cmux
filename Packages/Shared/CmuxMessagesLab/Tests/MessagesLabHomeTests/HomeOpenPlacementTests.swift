import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Where a chat opens (#27627): switching to a Chief makes a new transcript view for it, as
/// Messages opens a conversation. It lands on the newest message, or, when the person had
/// scrolled up in that chat earlier in this session, on the message they were reading.
///
/// Each test opens the view as Home does (`HomeNativeTranscriptView` in a new `HomeHostView`):
/// made at zero size, its rows installed from the store's cached transcript at once, then put in
/// the pane at the pane's size; the width change then measures every row again off main.
@MainActor @Suite(.serialized) struct HomeOpenPlacementTests {
    /// A new view of the rig's conversation, opened as Home opens one, settled.
    private func open(_ rig: HomeChatRig) async throws -> MessagesLabHomeView {
        let view = MessagesLabHomeView(store: rig.store, conversation: HomeChatRig.conversation, me: rig.me, wake: HomeChatRig.NoWake())
        view.setBareTop()
        let pane = try #require(rig.window.contentView)
        view.frame = pane.bounds
        pane.addSubview(view)
        pane.layoutSubtreeIfNeeded()
        await settle(view)
        return view
    }

    /// Waits for the off-main measure a width change starts (`measureWindow`), then lays out again.
    private func settle(_ view: MessagesLabHomeView) async {
        for _ in 0..<200 {
            view.superview?.layoutSubtreeIfNeeded()
            if let probe = view.controller.demo?.anchorProbe, probe.estimatedRows == 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<20 { await Task.yield() }
        view.superview?.layoutSubtreeIfNeeded()
        CATransaction.flush()
    }

    /// The view shows the newest message: pinned, at the bottom of its rows, the scroll view there too.
    private func expectAtNewest(_ view: MessagesLabHomeView, _ comment: Comment) throws {
        let demo = try #require(view.controller.demo)
        let store = try #require(view.controller.store)
        #expect(store.state.ui.scroll.pinnedToBottom, comment)
        #expect(abs(demo.collection.contentOffset.y - demo.pinnedOffset) < 1,
                "\(comment): offset \(demo.collection.contentOffset.y), bottom \(demo.pinnedOffset)")
    }

    /// The person scrolls the transcript up by `points` (a wheel moves the clip view; the model follows).
    private func scrollUp(_ view: MessagesLabHomeView, by points: CGFloat) throws {
        let demo = try #require(view.controller.demo)
        view.controller.host.scrollView.scroll(toModelOffset: demo.collection.contentOffset.y - points)
        demo.userScrolled()
        view.superview?.layoutSubtreeIfNeeded()
    }

    @Test func aChatOpensAtItsNewestMessage() async throws {
        let rig = try await HomeChatRig(history: 300)
        defer { rig.stop() }
        rig.view.stop()
        rig.view.removeFromSuperview()

        let view = try await open(rig)
        defer { view.stop() }
        try expectAtNewest(view, "a first open")
    }

    @Test func aChatLeftAtTheBottomOpensAtTheBottomWithWhatCameMeanwhile() async throws {
        let rig = try await HomeChatRig(history: 300)
        defer { rig.stop() }
        rig.view.stop()
        rig.view.removeFromSuperview()

        let first = try await open(rig)
        try expectAtNewest(first, "the first view")
        first.stop()
        first.removeFromSuperview()
        // Another Chief was shown while this one answered.
        #expect(await rig.post("\(HomeChatRig.tag) while you were away", key: IdempotencyKey("away")))

        let again = try await open(rig)
        defer { again.stop() }
        try expectAtNewest(again, "back at a chat left at the bottom")
        #expect(again.controller.store?.state.conversation.messages.last?.parts.contains { part in
            if case let .text(t, _) = part { t.hasSuffix("while you were away") } else { false }
        } == true)
    }

    @Test func aChatLeftScrolledUpOpensWhereThePersonWasReading() async throws {
        let rig = try await HomeChatRig(history: 300)
        defer { rig.stop() }
        rig.view.stop()
        rig.view.removeFromSuperview()

        let first = try await open(rig)
        try scrollUp(first, by: 2400)
        let left = try #require(first.controller.demo?.anchorProbe)
        #expect(first.controller.store?.state.ui.scroll.pinnedToBottom == false)
        first.stop()
        first.removeFromSuperview()

        let again = try await open(rig)
        defer { again.stop() }
        let back = try #require(again.controller.demo?.anchorProbe)
        #expect(back.key == left.key, "opened at row \(back.key), left at \(left.key)")
        #expect(abs(back.y - left.y) < 1, "the row sits at \(back.y), was at \(left.y)")
        #expect(again.controller.store?.state.ui.scroll.pinnedToBottom == false)
    }
}
