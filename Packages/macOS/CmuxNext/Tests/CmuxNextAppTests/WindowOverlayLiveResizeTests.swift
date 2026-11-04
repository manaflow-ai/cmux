import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S7, the overlay layer in a window's live resize (`WindowOverlayLayer`, owner PL-motion-cef). Each
/// drag AppKit applies in a live resize sets the window's frame and lays the whole tree out inside that `setFrame`
/// (profile winresize-profile-b08cc6f: the overlay's didResize handler runs inside `_setFrameCommon`, after the tree
/// layout). Per applied drag the overlay layer then asked the window's Chromium pages for a geometry update two to four
/// times (the layout's overlay sync, the didResize handler, the window layout pass after it) and moved every divider
/// catcher panel (one window server move each), though no click or hover can reach a divider while AppKit tracks the
/// resize. Now an applied drag posts one page update, after the tree layout, and the catcher panels stay until the
/// resize ends.
///
/// The rig is `WindowLiveResizeFrameTickTests`'s (a shell window, two panes, the right one resizes the window from each
/// drag it gets); `Motion.liveResizeOverride` stands for AppKit's live resize, and the test is the clock.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct WindowOverlayLiveResizeTests {
    /// Counts the window's page update requests (each one reaches every Chromium page of the window).
    final class PagePosts {
        private(set) var count = 0
        /// Diagnostics (nomerge): the phase and the cmux and AppKit frames of each post.
        var phase = ""
        private(set) var trail: [String] = []
        private var observer: (any NSObjectProtocol)?

        init(window: NSWindow) {
            // global-notice-allow: CEFHostView observes its window's page update request on the default center (the production path)
            observer = NotificationCenter.default.addObserver(forName: Notification.Name.browserChildWindowPagesNeedUpdate, object: window,
                                                              queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { // main-proof: the overlay layer posts on the main thread
                    guard let self else { return }
                    self.count += 1
                    let frames = Thread.callStackSymbols.dropFirst(2).filter { line in
                        ["Cmux", "NSWindow", "setFrame", "layout", "Layout", "display", "Display"].contains { line.contains($0) }
                    }.prefix(22).map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix { $0 != "+" }.joined(separator: " ") }
                    self.trail.append("[\(self.phase)] " + frames.joined(separator: " < "))
                }
            }
        }

        func stop() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }

    /// With `motion.frameOwner.liveResize` on (off is today's path, every request at once).
    @Test func aLiveResizeMovesNoCatcherPanelAndAsksThePagesOncePerAppliedDrag() throws {
        try WindowLiveResizeFrameTickTests.withSwitch(true) {
            let rig = WindowLiveResizeFrameTickTests.Rig()
            defer { rig.close() }
            let window = rig.window, layer = window.overlayLayer
            let posts = PagePosts(window: window)
            defer { posts.stop() }
            let press = try rig.pressPoint()
            window.sendEvent(rig.event(.leftMouseDown, press))
            Motion.liveResizeOverride = true
            defer { Motion.liveResizeOverride = nil }
            let catchers = layer.catcherAreas.map(\.rect)
            try #require(!catchers.isEmpty, "the split's divider has a catcher area: \(layer.dividerAreas)")
            let startWidth = window.frame.width

            for step in 1...3 {
                let before = posts.count, dividers = layer.dividerAreas.map(\.rect), trailStart = posts.trail.count
                posts.phase = "send"
                window.sendEvent(rig.event(.leftMouseDragged, CGPoint(x: press.x + 24 * CGFloat(step), y: press.y)))
                // The drag reaches AppKit's resize at the window's frame tick.
                posts.phase = "tick"
                rig.frameTick()
                // The display cycle's window layout pass of that turn.
                posts.phase = "layout"
                window.layoutIfNeeded()
                posts.phase = "after"
                let trail = posts.trail[trailStart...].joined(separator: "\n")
                #expect(posts.count - before == 1, "DIAG step \(step):\n\(trail)")
                #expect(window.frame.width == startWidth + 24 * CGFloat(step), "step \(step): the window is \(window.frame.width - startWidth) pt wider")
                #expect(layer.dividerAreas.map(\.rect) != dividers, "step \(step): the divider did not move; the test proves nothing")
                #expect(posts.count - before == 1, "step \(step): \(posts.count - before) page update requests for one applied drag")
                #expect(layer.catcherAreas.map(\.rect) == catchers,
                        "step \(step): the catcher panels moved mid-resize: \(catchers) -> \(layer.catcherAreas.map(\.rect))")
            }
            window.sendEvent(rig.event(.leftMouseUp, CGPoint(x: press.x + 72, y: press.y)))
        }
    }
}
