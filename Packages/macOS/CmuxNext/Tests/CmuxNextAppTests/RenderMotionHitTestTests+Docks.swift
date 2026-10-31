import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// Hit testing during a render-server spring beside dock columns: a strip pane unzooming
/// above a docked column takes the presses where it is drawn over the dock, and an overlay column's glass keeps
/// its presses while a docked column grows in on the other side and the strip's range springs.
extension RenderMotionHitTestTests {
    /// An overlay column on the left (pane `o`) over the strip's p1 and p2.
    static let overlaid = ScreenLayout.columns([
        LayoutColumn(id: "ov", width: 0.3, root: .leaf("o"), dock: DockColumn(edge: .left, mode: .overlay)),
        LayoutColumn(id: "c1", width: 0.5, root: .leaf("p1")),
        LayoutColumn(id: "c2", width: 0.5, root: .leaf("p2")),
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
    /// a press on the left overlay column's glass, off its pane, reaches no strip pane under the glass.
    ///
    /// The press must land where a strip pane is drawn under the glass, or the test passes with no guard at all.
    /// So p2 (the last strip column) has the focus, the strip scrolls to show it, and p1 slides under the overlay;
    /// the test then picks a point of the glass that p1 or p2 is drawn under at half way, and requires one.
    @Test func anOverlayGlassKeepsItsPressWhileADockGrowsIn() async throws {
        try await Render.withMotion {
            // The overlay's glass reaches half the strip gap past its pane. The default look (pane separation
            // `dividers`) has no strip gap, so its glass would be its pane and no press could land off the pane:
            // pin a column gap so the glass this test presses exists whatever the host's design settings are.
            let fixture = Screen(Self.overlaid, focused: "p2", columnGap: 12)
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            // Focusing p2 scrolls the strip: let that motion land first, so the dock arrives with every spring at rest
            // (a camera still moving keeps the arrival off the render server).
            _ = fixture.stepToRest()
            try #require(await fixture.renderSpringsDrained(), "the strip's scroll to p2 did not land")
            try #require(fixture.screen.scroll.value > 1, "the strip does not scroll to show p2, so no strip pane is under the overlay")
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
            let p1 = try fixture.host("p1"), p2 = try fixture.host("p2")
            let drawn1 = try Self.drawn(p1, at: half, clock: clock), drawn2 = try Self.drawn(p2, at: half, clock: clock)
            // On the glass, off its pane (right of the pane, else above it), with a strip pane drawn under it.
            var glass: [CGPoint] = []
            for x in stride(from: pane.maxX + 1, to: overlay.cover.maxX, by: 1) { glass.append(CGPoint(x: x, y: pane.midY)) }
            for y in stride(from: overlay.cover.minY + 1, to: pane.minY, by: 1) { glass.append(CGPoint(x: pane.midX, y: y)) }
            let local = try #require(glass.first { point in
                guard overlay.cover.contains(point), !pane.insetBy(dx: -1, dy: -1).contains(point) else { return false }
                let inWindow = screen.convert(point, to: nil)
                return drawn1.contains(inWindow) || drawn2.contains(inWindow)
            }, "no point of the overlay's glass (cover \(overlay.cover), pane \(pane)) has a strip pane drawn under it: p1 \(drawn1), p2 \(drawn2)")
            let container = try #require(screen.stripContainer.layer?.presentation(), "the strip container has no presentation")
            try #require(screen.convertFromLayer(container.frame).contains(local), "the strip is not drawn under the glass at \(local)")
            let hit = Self.hit(fixture, at: screen.convert(local, to: nil))
            #expect(!Self.reaches(hit, p1) && !Self.reaches(hit, p2), "a press on the overlay's glass reached the strip: \(String(describing: hit))")
            let pressed = screen.pressedPane(at: local)
            #expect(pressed != "p1" && pressed != "p2", "a press on the overlay's glass focuses the strip pane \(String(describing: pressed))")
        }
    }
}
