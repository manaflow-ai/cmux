#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import QuartzCore
import Testing

/// FRAME OWNER REFACTOR S7 diagnostic `motion.frameOwner.liveResize.pageAfterCommit` (DEBUG and bench builds): the films
/// show the page window moving one refresh BEFORE the main window, whose commit misses its refresh on every ON step. With
/// the diagnostic on, an applied drag's page update waits for the commit of its `setFrame` and goes at the first frame
/// tick after it, so the page moves at the refresh the window's commit shows. The test is the clock and the commit.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct WindowLiveResizePageAfterCommitTests {
    @Test func theAppliedDragsPageUpdateWaitsForItsCommitAndGoesAtTheNextTick() throws {
        try WindowLiveResizeFrameTickTests.withSwitch(true) {
            TunableStore.shared.set("motion.frameOwner.liveResize.pageAfterCommit", .bool(true))
            defer { TunableStore.shared.set("motion.frameOwner.liveResize.pageAfterCommit", nil) }
            let rig = WindowLiveResizeFrameTickTests.Rig()
            defer { rig.close() }
            let window = rig.window
            let posts = WindowOverlayLiveResizeTests.PagePosts(window: window)
            defer { posts.stop() }
            let press = try rig.pressPoint()
            window.sendEvent(rig.event(.leftMouseDown, press))
            Motion.liveResizeOverride = true
            defer { Motion.liveResizeOverride = nil }
            CATransaction.flush()

            // The display frame's first drag: AppKit applies it in this turn; its page update waits for the commit.
            let before = posts.count
            window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 24, y: press.y)))
            window.layoutIfNeeded()
            #expect(rig.edge.events == [.drag(press.x + 24)], "the drag did not reach the resize: \(rig.edge.events)")
            #expect(posts.count == before, "\(posts.count - before) page updates before the drag's commit")
            #expect(window.liveResizeInput.holdsUntilCommit, "the page update does not wait for the commit")
            // A frame tick before the commit: still nothing.
            rig.frameTick()
            #expect(posts.count == before, "\(posts.count - before) page updates at a tick before the commit")
            // The commit, then the next frame tick: one page update.
            CATransaction.flush()
            rig.frameTick()
            #expect(posts.count - before == 1, "\(posts.count - before) page updates at the first tick after the commit")
            #expect(!window.liveResizeInput.holdsUntilCommit, "the hold outlived its commit")
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 24, y: press.y)))
        }
    }

    /// The release lets what waits for a commit go before AppKit hears it, so the resize's end finds nothing held.
    @Test func theReleaseLetsAHeldPageUpdateGo() throws {
        try WindowLiveResizeFrameTickTests.withSwitch(true) {
            TunableStore.shared.set("motion.frameOwner.liveResize.pageAfterCommit", .bool(true))
            defer { TunableStore.shared.set("motion.frameOwner.liveResize.pageAfterCommit", nil) }
            let rig = WindowLiveResizeFrameTickTests.Rig()
            defer { rig.close() }
            let window = rig.window
            let posts = WindowOverlayLiveResizeTests.PagePosts(window: window)
            defer { posts.stop() }
            let press = try rig.pressPoint()
            window.sendEvent(rig.event(.leftMouseDown, press))
            Motion.liveResizeOverride = true
            defer { Motion.liveResizeOverride = nil }
            let before = posts.count
            window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 24, y: press.y)))
            #expect(window.liveResizeInput.holdsUntilCommit)
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 24, y: press.y)))
            #expect(!window.liveResizeInput.holdsUntilCommit, "the release left the page update held")
            #expect(posts.count - before >= 1, "the release sent no page update")
        }
    }
}
#endif
