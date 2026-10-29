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
    @Test func anOverlayGlassKeepsItsPressWhileADockGrowsIn() async throws {
        try await Render.withMotion {
            let fixture = Screen(Self.overlaid, focused: "p1")
            defer { fixture.close() }
            try #require(fixture.window.screen != nil, "the window is on no screen: nothing animates")
            let clock = try #require(fixture.root.layer)
            Render.freeze(clock)
            fixture.apply(Self.overlaidAndDocked)
            let screen = fixture.screen
            try #require(screen.renderTracks.strip, "the strip's range does not spring on the render server")
            let half = Render.time(toProgress: 0.5, Motion.panes.spring(screen.motionState.frameSpring))
            Render.seek(clock, to: half)
            let overlay = try #require(screen.geometry.dock.first { $0.dock.mode == .overlay }, "no overlay column")
            let pane = try fixture.host("o").frame
            // On the glass, off its pane: right of the pane, else above it.
            let candidates = [CGPoint(x: (pane.maxX + overlay.cover.maxX) / 2, y: pane.midY),
                              CGPoint(x: pane.midX, y: (overlay.cover.minY + pane.minY) / 2)]
            let local = try #require(candidates.first { overlay.cover.contains($0) && !pane.insetBy(dx: -1, dy: -1).contains($0) },
                                     "the overlay's cover \(overlay.cover) has no glass off its pane \(pane)")
            let container = try #require(screen.stripContainer.layer?.presentation(), "the strip container has no presentation")
            try #require(screen.convertFromLayer(container.frame).contains(local), "the strip is not drawn under the glass at \(local)")
            let hit = Self.hit(fixture, at: screen.convert(local, to: nil))
            let p1 = try fixture.host("p1"), p2 = try fixture.host("p2")
            #expect(!Self.reaches(hit, p1) && !Self.reaches(hit, p2), "a press on the overlay's glass reached the strip: \(String(describing: hit))")
            let pressed = screen.pressedPane(at: local)
            #expect(pressed != "p1" && pressed != "p2", "a press on the overlay's glass focuses the strip pane \(String(describing: pressed))")
        }
    }
}
