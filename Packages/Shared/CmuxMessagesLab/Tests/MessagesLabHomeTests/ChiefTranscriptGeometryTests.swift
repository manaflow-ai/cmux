import AppKit
import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The v3f transcript geometry fixes: the header's band follows the rows under it on every
/// change (not only a scroll), the transcript keeps following its newest row across a size
/// change, hosted rows draw again after a reflow, the debug scroll stays in the content, the
/// done checkmark is legible and the pill clears the avatar.
@MainActor @Suite(.serialized) struct ChiefTranscriptGeometryTests {
    typealias Harness = HomeHarnessTests

    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    /// A pane of `size` showing the harness conversation's first `count` messages, laid out.
    static func pane(count: Int, size: CGSize = CGSize(width: 600, height: 700)) -> ChatController {
        let host = HostView(frame: CGRect(origin: .zero, size: size))
        let controller = ChatController(host: host, wake: NoWake())
        var core = ProjectionCore(me: Harness.me)
        let items: [TranscriptItem] = Array(Harness.base.prefix(count))
        let (conv, w) = core.install(Harness.id, items: items, summary: Harness.summary(lastSeq: Seq(count)))
        controller.install(conv, windowStart: w.start, total: w.total)
        host.layoutSubtreeIfNeeded()
        return controller
    }

    static func receive(_ controller: ChatController, _ n: Int) {
        for i in 0..<n {
            let text: String = "Arrived \(i): a reply long enough to take a line of its own in the transcript."
            controller.dispatch(.receive(Harness.lab("r\(i)", Harness.them, text, at: Double(i))))
        }
    }

    // MARK: Header band

    @Test func theBandFollowsTheRowsUnderIt() {
        #expect(HostView.headerRevealed(hovered: false, revealsWhenScrolled: true, rowsTop: 60, band: 107))
        #expect(!HostView.headerRevealed(hovered: false, revealsWhenScrolled: true, rowsTop: 300, band: 107))
        #expect(!HostView.headerRevealed(hovered: false, revealsWhenScrolled: true, rowsTop: nil, band: 107))
        #expect(!HostView.headerRevealed(hovered: false, revealsWhenScrolled: false, rowsTop: 60, band: 107))
        #expect(HostView.headerRevealed(hovered: true, revealsWhenScrolled: false, rowsTop: nil, band: 107))
        // The oldest row just under the 80 pt header still lies under an extended band (v3f f2: the
        // model line over "Today").
        #expect(HostView.headerRevealed(hovered: false, revealsWhenScrolled: true, rowsTop: 88, band: 107))
    }

    /// P0-2: rows that arrive and push the others under the header show the band with no scroll event.
    @Test func newRowsUnderTheHeaderShowTheBandWithoutAScroll() {
        let controller = Self.pane(count: 2)
        let host = controller.host
        host.headerFadeExtent = 107
        host.headerBackdrop.useTopFade(color: .black, maxAlpha: 0.94, solid: 89.0 / 107.0)
        host.headerRevealsWhenScrolled = true
        host.applyHeaderReveal()
        #expect(host.headerBackdrop.revealOpacity == 0)
        Self.receive(controller, 30)
        let top: CGFloat = host.transcriptRowsTop ?? .infinity
        #expect(top < host.headerBandHeight)
        #expect(host.headerBackdrop.revealOpacity == 1)
    }

    // MARK: Following the newest row

    @Test func onlyThePersonsScrollStopsTheFollowing() {
        #expect(HostView.isPersonScroll(event: .scrollWheel, eventAge: 0.01, liveScrolling: false, sinceSizeChange: 5))
        #expect(HostView.isPersonScroll(event: nil, eventAge: .infinity, liveScrolling: true, sinceSizeChange: 0))
        // A clip move inside a size change (the settings panel's slide), or with a stale or unrelated event.
        #expect(!HostView.isPersonScroll(event: .scrollWheel, eventAge: 0.01, liveScrolling: false, sinceSizeChange: 0.05))
        #expect(!HostView.isPersonScroll(event: .leftMouseUp, eventAge: 0.01, liveScrolling: false, sinceSizeChange: 5))
        #expect(!HostView.isPersonScroll(event: .keyDown, eventAge: 3, liveScrolling: false, sinceSizeChange: 5))
        #expect(HostView.shouldRepin(following: true, pinned: false, atNewest: true, offsetOffPin: true, sizeChanged: false))
        #expect(HostView.shouldRepin(following: true, pinned: true, atNewest: true, offsetOffPin: true, sizeChanged: true))
        #expect(!HostView.shouldRepin(following: true, pinned: true, atNewest: true, offsetOffPin: true, sizeChanged: false))
        #expect(!HostView.shouldRepin(following: false, pinned: false, atNewest: true, offsetOffPin: true, sizeChanged: true))
        #expect(!HostView.shouldRepin(following: true, pinned: false, atNewest: false, offsetOffPin: true, sizeChanged: true))
    }

    /// P1 (v3f light-k): a pin dropped by a size change, not by the person, comes back with the next message.
    @Test func aPinDroppedByAResizeComesBackWithTheNextMessage() {
        let controller = Self.pane(count: 30)
        guard let store = controller.store, let demo = controller.demo else { Issue.record("no store"); return }
        #expect(store.state.ui.scroll.pinnedToBottom)
        // Narrower and back (the panel opening and closing), then a move that is not the person's.
        controller.host.setFrameSize(CGSize(width: 340, height: 700))
        controller.host.layoutSubtreeIfNeeded()
        controller.host.setFrameSize(CGSize(width: 600, height: 700))
        controller.host.layoutSubtreeIfNeeded()
        store.dispatch(.setScroll(offset: 120, pinned: false))
        Self.receive(controller, 1)
        #expect(store.state.ui.scroll.pinnedToBottom)
        let off: CGFloat = abs(demo.collection.contentOffset.y - demo.pinnedOffset)
        #expect(off < 1)
    }

    @Test func aPinThePersonLeftStaysLeft() {
        let controller = Self.pane(count: 30)
        guard let store = controller.store else { Issue.record("no store"); return }
        store.dispatch(.setScroll(offset: 120, pinned: false))
        controller.host.followsNewest = false
        Self.receive(controller, 1)
        #expect(!store.state.ui.scroll.pinnedToBottom)
    }

    // MARK: Debug scroll

    @Test func theDebugScrollStaysInTheContent() {
        #expect(MessagesLabHomeView.clampedScrollOffset(2400, min: -40, max: 800) == 800)
        #expect(MessagesLabHomeView.clampedScrollOffset(-900, min: -40, max: 800) == -40)
        #expect(MessagesLabHomeView.clampedScrollOffset(300, min: -40, max: 800) == 300)
        #expect(MessagesLabHomeView.clampedScrollOffset(.nan, min: -40, max: 800) == -40)
    }

    // MARK: Hosted rows draw again

    @Test func aDrawnRowDrawsAgainAfterAReflowOrReuse() {
        let view = ChiefFailureRowView(frame: CGRect(x: 0, y: 0, width: 400, height: 52))
        view.show(ChiefRows.Failure(id: "f1", text: "I couldn’t finish: the socket closed.", retry: true))
        let before = view.redrawRequests
        view.setFrameSize(CGSize(width: 320, height: 52))
        #expect(view.redrawRequests == before + 1)
        view.setFrameSize(CGSize(width: 320, height: 52))
        #expect(view.redrawRequests == before + 1)
        view.reset()
        #expect(view.redrawRequests == before + 2)
        let stopped = ChiefStoppedRowView(frame: CGRect(x: 0, y: 0, width: 400, height: 22))
        let start = stopped.redrawRequests
        stopped.setFrameSize(CGSize(width: 300, height: 22))
        #expect(stopped.redrawRequests == start + 1)
    }

    // MARK: Checkmark and header

    @Test func theDoneCheckmarkHasThreeToOneContrast() {
        let pairs: [(NSColor, NSColor)] = [
            (NSColor(white: 134 / 255, alpha: 1), .white),
            (NSColor(white: 154 / 255, alpha: 1), NSColor(white: 30 / 255, alpha: 1)),
            (NSColor(white: 0.8, alpha: 1), .white),
            (NSColor(white: 0.3, alpha: 1), NSColor(white: 0.12, alpha: 1)),
        ]
        for (secondary, background) in pairs {
            let check = ChiefToolRowView.checkColor(secondary: secondary, background: background)
            #expect(ChiefToolRowView.contrast(check, background) >= ChiefToolRowView.checkMinContrast)
        }
        // A secondary colour that already reads is kept.
        let kept = ChiefToolRowView.checkColor(secondary: NSColor(white: 134 / 255, alpha: 1), background: .white)
        #expect(abs(ChiefToolRowView.luminance(kept) - ChiefToolRowView.luminance(NSColor(white: 134 / 255, alpha: 1))) < 0.001)
    }

    @Test func thePillClearsTheAvatar() {
        #expect(PaneHeaderView.avatarPillGap >= 4)
    }
}
