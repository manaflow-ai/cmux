import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S7, the end of a window's live resize for the overlay layer (`WindowOverlayLayer`, owner
/// PL-motion-cef): the divider catcher panels, which stayed where they were through the resize
/// (`WindowOverlayLiveResizeTests`), take the dividers' places once when it ends, and the pages hear the final geometry
/// once. AppKit tells the end with `didEndLiveResize`, which the layer hears on the default center; a test does not post
/// it there (check-test-notification-centers.sh), so it calls the layer's handler of that notice.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct WindowOverlayLiveResizeEndTests {
    @Test func theResizeEndMovesTheCatchersOnceOntoTheDividersAndAsksThePagesOnce() throws {
        try WindowLiveResizeFrameTickTests.withSwitch(true) {
            let rig = WindowLiveResizeFrameTickTests.Rig()
            defer { rig.close() }
            let window = rig.window, layer = window.overlayLayer
            let posts = WindowOverlayLiveResizeTests.PagePosts(window: window)
            defer { posts.stop() }
            let press = try rig.pressPoint()
            window.sendEvent(rig.event(.leftMouseDown, press))
            Motion.liveResizeOverride = true
            defer { Motion.liveResizeOverride = nil }
            let catchers = layer.catcherAreas.map(\.rect)
            for step in 1...3 {
                window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 24 * CGFloat(step), y: press.y)))
                rig.frameTick()
                window.layoutIfNeeded()
            }
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 72, y: press.y)))
            try #require(layer.catcherAreas.map(\.rect) == catchers, "the catchers moved during the resize; WindowOverlayLiveResizeTests covers it")
            try #require(layer.dividerAreas.map(\.rect) != catchers, "the divider did not move; the test proves nothing")

            // AppKit ends the live resize.
            Motion.liveResizeOverride = false
            let before = posts.count
            layer.liveResizeDidEnd()
            #expect(layer.catcherAreas.map(\.rect) == layer.dividerAreas.map(\.rect),
                    "the catchers stayed off the dividers after the resize: \(layer.catcherAreas.map(\.rect)) vs \(layer.dividerAreas.map(\.rect))")
            #expect(posts.count - before == 1, "\(posts.count - before) page update requests at the resize's end")
        }
    }
}
