import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Where a chat opens (#27627): switching to a Chief makes a new transcript view for it, as
/// Messages opens a conversation. It lands on the newest message, or, when the person had
/// scrolled up in that chat, on the message they were reading, at the same distance above the
/// field.
///
/// Each test opens the view in Home's order (`HomeNativeTranscriptView` in a new `HomeHostView`):
/// made with no size (its rows installed from the store's cached transcript in init, at the
/// controller's fixture size), added to the pane at zero size, then given the pane's size by a
/// later layout; a width change then measures every row again off main.
@MainActor @Suite(.serialized) struct HomeOpenPlacementTests {
    /// A new view of the rig's conversation, opened as Home opens one, settled.
    private func open(_ rig: HomeChatRig, height: CGFloat? = nil) async throws -> MessagesLabHomeView {
        let view = MessagesLabHomeView(store: rig.store, conversation: HomeChatRig.conversation, me: rig.me, wake: HomeChatRig.NoWake())
        view.setBareTop()
        let pane = try #require(rig.window.contentView)
        if let height { rig.window.setContentSize(NSSize(width: pane.frame.width, height: height)) }
        pane.addSubview(view)
        pane.layoutSubtreeIfNeeded()
        view.frame = pane.bounds
        pane.layoutSubtreeIfNeeded()
        await settle(view)
        return view
    }

    /// The place a closing view keeps: the newest message on screen and its bottom's distance from the field.
    /// Nil (recorded as an issue, with the view's state) when the view shows its newest message.
    private func place(_ view: MessagesLabHomeView, _ which: String) -> (message: String, offset: CGFloat)? {
        let place = view.controller.demo?.readingPlace(keeps: { _ in true })
        if place == nil {
            let pinned = view.controller.store?.state.ui.scroll.pinnedToBottom == true
            Issue.record("\(which): no place; pinned \(pinned), placed \(!view.projection.placesOnOpen)")
        }
        return place
    }

    /// The chat's view closes, as Home drops it for another Chief's (its pane stays in the window).
    private func close(_ view: MessagesLabHomeView, in rig: HomeChatRig) {
        view.stop()
        if rig.window.contentView === view {
            rig.window.contentView = NSView(frame: view.frame)
        } else {
            view.removeFromSuperview()
        }
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

    /// The person scrolls the transcript up by `points` within the loaded rows (a wheel moves the clip
    /// view; the model follows).
    private func scrollUp(_ view: MessagesLabHomeView, by points: CGFloat) throws {
        let demo = try #require(view.controller.demo)
        view.controller.host.scrollView.scroll(toModelOffset: max(demo.minOffset, demo.collection.contentOffset.y - points))
        demo.userScrolled()
        view.superview?.layoutSubtreeIfNeeded()
    }

    @Test func aChatOpensAtItsNewestMessage() async throws {
        let rig = try await HomeChatRig(history: 300)
        defer { rig.stop() }
        close(rig.view, in: rig)

        let view = try await open(rig)
        defer { view.stop() }
        try expectAtNewest(view, "a first open")
    }

    @Test func aChatLeftAtTheBottomOpensAtTheBottomWithWhatCameMeanwhile() async throws {
        let rig = try await HomeChatRig(history: 300)
        defer { rig.stop() }
        close(rig.view, in: rig)

        let first = try await open(rig)
        try expectAtNewest(first, "the first view")
        close(first, in: rig)
        // Another Chief was shown while this one answered.
        #expect(await rig.post("\(HomeChatRig.tag) while you were away", key: IdempotencyKey("away")))

        let again = try await open(rig)
        defer { again.stop() }
        try expectAtNewest(again, "back at a chat left at the bottom")
        #expect(again.controller.store?.state.conversation.messages.last?.parts.contains { part in
            if case let .text(t, _) = part { t.hasSuffix("while you were away") } else { false }
        } == true)
    }

    @Test(arguments: [nil, 1100.0] as [CGFloat?])
    func aChatLeftScrolledUpOpensWhereThePersonWasReading(reopenHeight: CGFloat?) async throws {
        let rig = try await HomeChatRig(history: 300)
        defer { rig.stop() }
        close(rig.view, in: rig)

        let first = try await open(rig)
        try scrollUp(first, by: 600)
        #expect(!first.projection.placesOnOpen, "the first view was placed")
        guard let left = place(first, "scrolled up") else { return }
        close(first, in: rig)
        let kept = rig.store.scrollAnchor(for: HomeChatRig.conversation)
        #expect(kept != nil, "the closed view kept its place")

        // The same pane, or a taller one (the window grew meanwhile): the message keeps its distance from the field.
        let again = try await open(rig, height: reopenHeight)
        defer { again.stop() }
        guard let back = place(again, "reopened with \(String(describing: kept))") else { return }
        #expect(back.message == left.message, "opened at message \(back.message), left at \(left.message)")
        #expect(abs(back.offset - left.offset) < 1, "its bubble ends \(back.offset) pt above the field, was \(left.offset)")
        #expect(again.controller.store?.state.ui.scroll.pinnedToBottom == false)
    }

    @Test func aChatScrolledUpThenBackToTheBottomOpensAtTheNewest() async throws {
        let rig = try await HomeChatRig(history: 300)
        defer { rig.stop() }
        close(rig.view, in: rig)

        // A place kept by an earlier view of this chat.
        let first = try await open(rig)
        try scrollUp(first, by: 600)
        close(first, in: rig)
        #expect(rig.store.scrollAnchor(for: HomeChatRig.conversation) != nil)

        // Back at the newest message this time: that is what the next view shows.
        let second = try await open(rig)
        let demo = try #require(second.controller.demo)
        second.controller.host.scrollView.scroll(toModelOffset: demo.pinnedOffset)
        demo.userScrolled()
        close(second, in: rig)
        #expect(rig.store.scrollAnchor(for: HomeChatRig.conversation) == nil)

        let again = try await open(rig)
        defer { again.stop() }
        try expectAtNewest(again, "back at a chat last left at the bottom")
    }

    @Test func aChatScrolledBackDownForgetsItsPlaceWithoutClosing() async throws {
        let rig = try await HomeChatRig(history: 300)
        defer { rig.stop() }
        close(rig.view, in: rig)

        let first = try await open(rig)
        try scrollUp(first, by: 600)
        close(first, in: rig)
        #expect(rig.store.scrollAnchor(for: HomeChatRig.conversation) != nil)

        // Opened at the kept place, then scrolled back to the newest message. The app quits (or
        // crashes) without closing the view: the Home cache must not keep the old place.
        let second = try await open(rig)
        defer { second.stop() }
        let demo = try #require(second.controller.demo)
        second.controller.host.scrollView.scroll(toModelOffset: demo.pinnedOffset)
        demo.userScrolled()
        second.superview?.layoutSubtreeIfNeeded()
        #expect(rig.store.scrollAnchor(for: HomeChatRig.conversation) == nil, "the place is forgotten at the newest message")
    }

    @Test func aKeptPlaceWhoseMessageIsNotLoadedOpensAtTheNewest() async throws {
        let rig = try await HomeChatRig(history: 300)
        defer { rig.stop() }
        close(rig.view, in: rig)
        rig.store.setScrollAnchor(HomeScrollAnchor(message: MessageID("msg_not_loaded"), offset: 300), for: HomeChatRig.conversation)

        // The kept message is not in the loaded window (older than its pages, or gone): the newest message.
        let view = try await open(rig)
        defer { view.stop() }
        try expectAtNewest(view, "a place whose row is gone")
    }
}
