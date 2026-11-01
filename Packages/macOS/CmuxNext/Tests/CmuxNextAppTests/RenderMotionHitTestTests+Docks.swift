import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// Hit testing during a render-server spring beside dock columns: a strip pane unzooming
/// above a docked column takes the presses where it is drawn over the dock, and an overlay column's glass keeps
/// its presses while a docked column grows in on the other side and the strip's range springs.
extension RenderMotionHitTestTests {
    /// An overlay column on the left (pane `o`) over a strip of three 0.3-wide columns p1, p2, p3: wider than
    /// the strip, so it scrolls, and p1 can sit under the overlay with the camera at rest.
    static let overlaid = ScreenLayout.columns([
        LayoutColumn(id: "ov", width: 0.3, root: .leaf("o"), dock: DockColumn(edge: .left, mode: .overlay)),
        LayoutColumn(id: "c1", width: 0.3, root: .leaf("p1")),
        LayoutColumn(id: "c2", width: 0.3, root: .leaf("p2")),
        LayoutColumn(id: "c3", width: 0.3, root: .leaf("p3")),
    ])
    /// The same, with a new docked column on the right holding `chat`.
    static let overlaidAndDocked = ScreenLayout.columns(overlaid.columns + [
        LayoutColumn(id: "dock", width: 0.3, root: .leaf("chat"), dock: DockColumn(edge: .right, mode: .docked)),
    ])

    /// p1 unzooms beside the docked chat column: early in the spring it is still drawn over the dock's cover,
    /// in the strip container the zoom lifted above the dock. A press there reaches p1 and focuses it, not the
    /// dock pane resting behind it.
    @Test func aPressOverADockReachesTheUnzoomingPaneDrawnThere() async throws {
        try await Render.withMotion {
            let grid = ZoomRenderMotionTests.Grid(renderServer: true, layout: ZoomRenderMotionTests.docked)
            defer { grid.close() }
            try #require(grid.window.screen != nil, "the window is on no screen: nothing animates")
            grid.zoom()
            #expect(await grid.landed(), "the zoom did not land in 5 s")
            let clock = try #require(grid.root.layer)
            Render.freeze(clock)
            grid.motion = []
            grid.unzoom()
            let screen = grid.screen, p1 = try grid.host("p1")
            try #require(screen.zoomMotion.rendersOnServer && !screen.renderTracks.isEmpty, "the unzoom is not on the render server")
            try #require(screen.stripContainer.isLifted, "the strip container is not lifted above the dock")
            let dock = try #require(screen.geometry.dock.first, "the unzoomed layout has no docked column")
            let drawn = try Self.drawn(p1, at: 0.02, clock: clock)
            let under = drawn.intersection(screen.convert(dock.cover, to: nil))
            try #require(!under.isNull && under.width > 20, "p1 is not drawn over the dock's cover early in the unzoom: \(drawn)")
            let point = CGPoint(x: under.midX, y: under.midY)
            let hit = Self.hit(grid.root, at: point)
            #expect(Self.reaches(hit, p1), "the press drawn in p1 over the dock reached \(String(describing: hit))")
            #expect(screen.pressedPane(at: screen.convert(point, from: nil)) == "p1", "the press focuses another pane than p1")
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
                                                        windowNumber: grid.window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            _ = grid.root.handleMonitored(event)
            #expect(grid.model.focusedPane == "p1", "the press focused \(String(describing: grid.model.focusedPane))")
        }
    }

    /// A docked column grows in on the right while the strip's range springs (``ScreenContentView/RenderTracks/strip``):
    /// a press on the left overlay column's glass, off its pane, over a strip pane drawn under the glass, reaches no
    /// strip pane (``ScreenContentView`` `stripPoint`'s overlay-cover rule).
    ///
    /// Set-up (review of fc2cf77cfb5): an overlay gives the strip a leading inset of its width plus a gap, so a strip
    /// pane is under its glass only with the strip scrolled; and a dock arrival springs on the render server only with
    /// no camera moving. Focusing p3 scrolls the strip to its end; focusing p2 then keeps the camera (p2 is fully
    /// shown) and leaves p1 under the glass. The docked column narrows every strip column and the reducer keeps p2's
    /// left edge with value and target moved together, so the camera stays at rest and the arrival goes to the render
    /// server. The column gap is pinned: the default look has no strip gap, so its glass would be its pane.
    ///
    /// What it proves: the OUTCOME (no strip pane takes the press), not `stripPoint`'s overlay-cover rule alone. With
    /// that rule removed the test still passed on screen minis (2026-11-01, 4f27c26fce7 and 1e5d18677f6), so another
    /// path also stops the press. Most likely (read, not proven): the fixture has rows on, so each strip host sits in
    /// its column's row container, and `stripChildHit` skips a clipping row container whose resting frame does not
    /// hold the point. Keep the test; do not cite it as the only cover of the overlay-cover rule.
    @Test func anOverlayGlassKeepsItsPressWhileADockGrowsIn() async throws {
        try await Render.withMotion {
            let fixture = Screen(Self.overlaid, focused: "p3", columnGap: 12)
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            fixture.focus("p2")
            _ = fixture.stepToRest()
            try #require(await fixture.renderSpringsDrained(), "the strip's motion before the dock did not land")
            try #require(fixture.screen.scroll.value > 1, "the strip is not scrolled, so no strip pane is under the overlay")
            try #require(abs(fixture.screen.scroll.value - fixture.screen.scroll.target) < 0.5, "the strip camera still moves before the dock arrives")
            let clock = try #require(fixture.root.layer)
            Render.freeze(clock)
            fixture.apply(Self.overlaidAndDocked)
            let screen = fixture.screen
            try #require(screen.renderTracks.strip, "the strip's range does not spring on the render server")
            let half = Render.time(toProgress: 0.5, Motion.panes.spring(screen.motionState.frameSpring))
            Render.seek(clock, to: half)
            let overlay = try #require(screen.geometry.dock.first { $0.dock.mode == .overlay }, "no overlay column")
            let pane = try fixture.host("o").frame
            let strip = try ["p1", "p2", "p3"].map { try fixture.host($0) }
            // Where a strip pane is drawn, the way the press path maps it (ScreenContentView.stripPoint, then
            // PaneHostView.restPoint): the strip container springs too, so a point goes through the container's
            // presented frame and bounds into its layer, then into each host's presented frame there.
            let container = try #require(screen.stripContainer.layer?.presentation(), "the strip container has no presentation")
            let hosts = try strip.map { try #require($0.layer?.presentation(), "\($0.pane) has no presentation") }
            func drawnPane(at point: CGPoint) -> PaneID? {
                let inLayer = screen.convertToLayer(point)
                guard container.frame.contains(inLayer) else { return nil }
                let inner = CGPoint(x: inLayer.x - container.frame.minX + container.bounds.minX,
                                    y: inLayer.y - container.frame.minY + container.bounds.minY)
                return zip(strip, hosts).first { $0.1.frame.contains(inner) }?.0.pane
            }
            // On the glass, off its pane (right of the pane, else above it), with a strip pane drawn under it.
            var glass: [CGPoint] = []
            for x in stride(from: pane.maxX + 1, to: overlay.cover.maxX, by: 1) { glass.append(CGPoint(x: x, y: pane.midY)) }
            for y in stride(from: overlay.cover.minY + 1, to: pane.minY, by: 1) { glass.append(CGPoint(x: pane.midX, y: y)) }
            let local = try #require(glass.first { point in
                overlay.cover.contains(point) && !pane.insetBy(dx: -1, dy: -1).contains(point) && drawnPane(at: point) != nil
            }, "no point of the overlay's glass (cover \(overlay.cover), pane \(pane)) has a strip pane drawn under it: container drawn \(container.frame) bounds \(container.bounds), hosts \(hosts.map(\.frame))")
            let under = try #require(drawnPane(at: local))
            let hit = Self.hit(fixture, at: screen.convert(local, to: nil))
            #expect(!strip.contains { Self.reaches(hit, $0) }, "a press on the overlay's glass over \(under) reached the strip: \(String(describing: hit))")
            let pressed = screen.pressedPane(at: local)
            #expect(!["p1", "p2", "p3"].contains(pressed), "a press on the overlay's glass focuses the strip pane \(String(describing: pressed))")
        }
    }
}
