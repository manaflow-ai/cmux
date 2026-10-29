import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// What stacks over and under a zoom on the render server: the rings, dims and page cutouts of the panes it
/// covers or uncovers leave out all it springs across (its model frame is at rest from the key's turn), a
/// page in its own window keeps the zoom on the CPU step, and beside a docked column the zooming pane stays
/// above the dock until it lands.
extension ZoomRenderMotionTests {
    /// True when one of `covers` holds `rect` (within half a point).
    static func hides(_ covers: [CGRect], _ rect: CGRect) -> Bool {
        covers.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(rect) }
    }

    @Test func aZoomHidesTheCoveredPanesChromeAndPagesUnderAllItSpringsAcross() async throws {
        try await Render.withMotion {
            let grid = Grid(renderServer: true)
            defer { grid.close() }
            try #require(grid.window.screen != nil, "the window is on no screen: nothing animates")
            grid.zoom()
            let screen = grid.screen
            try #require(screen.zoomMotion.rendersOnServer, "the zoom is not on the render server")
            let rest = try grid.host("p1").frame
            for pane in Self.others {
                let other = try grid.host(pane)
                let under = rest.intersection(other.frame)
                #expect(Self.hides(grid.ringCovers(other), under), "\(pane)'s ring and dim draw over where p1 rests")
                #expect(Self.hides(other.pageCovers(), other.convert(under, from: screen)), "\(pane)'s page draws over where p1 rests")
            }
        }
    }

    /// An unzoom: p1's frame is its slot from the key's turn while it still shows full size. The returning
    /// panes' rings, dims and pages stay off all of that until it lands, then show whole.
    @Test func anUnzoomKeepsTheReturningPanesChromeOffWhereTheZoomedPaneStillShows() async throws {
        try await Render.withMotion {
            let grid = Grid(renderServer: true)
            defer { grid.close() }
            try #require(grid.window.screen != nil, "the window is on no screen: nothing animates")
            grid.zoom()
            #expect(await grid.landed(), "the zoom did not land in 5 s")
            let zoomed = try grid.host("p1").frame
            grid.motion = []
            grid.unzoom()
            let screen = grid.screen
            try #require(screen.zoomMotion.rendersOnServer, "the unzoom is not on the render server")
            grid.root.resyncOverlay()
            for pane in Self.others {
                let other = try grid.host(pane)
                let shown = zoomed.intersection(other.frame)
                try #require(!shown.isNull && shown.width > 1, "p1 does not show over \(pane) as the unzoom starts")
                #expect(Self.hides(grid.ringCovers(other), shown), "\(pane)'s ring and dim draw over p1 as it shrinks")
                #expect(Self.hides(other.overlaySyncKey?.covers ?? [], shown), "the overlay placed \(pane)'s chrome over p1")
                #expect(Self.hides(other.pageCovers(), other.convert(shown, from: screen)), "\(pane)'s page draws over p1 as it shrinks")
            }
            #expect(await grid.landed(), "the unzoom did not land in 5 s")
            #expect(screen.panesAbove().isEmpty, "a pane still hides another after the unzoom landed: \(screen.panesAbove())")
        }
    }

    /// A page drawing in its own window follows the model frames, not a Core Animation spring: a zoom over it
    /// steps on the CPU, where its cutouts follow the zooming pane on every frame.
    @Test func aPageInItsOwnWindowKeepsTheZoomOnTheCPUStep() async throws {
        try await Render.withMotion {
            let grid = Grid(renderServer: true)
            defer { grid.close() }
            try #require(grid.window.screen != nil, "the window is on no screen: nothing animates")
            grid.root.driver.isManual = true
            try #require(grid.panes.contents["p2"]).addSubview(Page(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
            grid.zoom()
            let screen = grid.screen
            #expect(screen.hasMotion && screen.zoomMotion.pane == "p1", "the zoom does not spring on the CPU")
            #expect(!screen.zoomMotion.rendersOnServer && screen.renderSpringsInFlight == 0, "the zoom over a page window is on the render server")
            #expect(try grid.host("p1").layer?.animationKeys()?.isEmpty ?? true, "p1 has render-server springs")
            for _ in 0..<480 where !grid.root.advanceFrame(1.0 / 120) { break }
            #expect(!screen.hasMotion && screen.zoomMotion.pane == nil && screen.covered.isEmpty, "the CPU zoom did not land")
        }
    }

    /// The same page hosted in the window's layer tree is ordered with the views: the zoom goes to the render server.
    @Test func aLayerHostedPageLetsTheZoomRunOnTheRenderServer() async throws {
        try await Render.withMotion {
            let grid = Grid(renderServer: true)
            defer { grid.close() }
            try #require(grid.window.screen != nil, "the window is on no screen: nothing animates")
            let page = Page(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            page.drawsInChildWindow = false
            try #require(grid.panes.contents["p2"]).addSubview(page)
            grid.zoom()
            #expect(!grid.screen.hasMotion && grid.screen.zoomMotion.rendersOnServer, "the zoom over a layer-hosted page stays on the CPU")
            #expect(await grid.landed(), "the zoom did not land in 5 s")
        }
    }

    /// A strip pane beside a docked column zooms and unzooms on the render server: the strip container is
    /// lifted above the dock for the whole spring and back at the strip's range, under the dock, once it lands.
    @Test func aStripPaneZoomsAboveADockAndTheLandingRestoresTheStacking() async throws {
        try await Render.withMotion {
            let grid = Grid(renderServer: true, layout: Self.docked)
            defer { grid.close() }
            try #require(grid.window.screen != nil, "the window is on no screen: nothing animates")
            let screen = grid.screen, container = screen.stripContainer
            try #require(!screen.hasMotion && !screen.geometry.dock.isEmpty, "the docked layout is not at rest")
            let chat = try grid.host("chat"), p1 = try grid.host("p1"), p2 = try grid.host("p2")
            let range = container.frame
            grid.zoom()
            #expect(!screen.hasMotion && screen.zoomMotion.pane == "p1" && screen.zoomMotion.rendersOnServer,
                    "the zoom beside a dock is not on the render server")
            #expect(Set(screen.covered) == ["chat", "p2"], "covered \(screen.covered)")
            #expect(container.isLifted && grid.frontHost === p1, "p1 is not lifted above the dock")
            let order = screen.subviews
            #expect((order.firstIndex(of: chat) ?? .max) < (order.firstIndex(of: container) ?? -1), "the dock is above the lifted strip")
            let shown = screen.shownFrame(p2)
            #expect(shown.isNull || range.insetBy(dx: -0.5, dy: -0.5).contains(shown), "the covered strip pane shows \(shown) past \(range)")
            #expect(await grid.landed(), "the zoom did not land in 5 s")
            #expect(!container.isLifted && screen.covered.isEmpty && chat.superview == nil && p2.superview == nil)
            #expect(p1.superview === container && p1.layer?.backgroundColor == nil)

            grid.motion = []
            grid.unzoom()
            let dock = try grid.host("chat")
            #expect(!screen.hasMotion && screen.zoomMotion.rendersOnServer, "the unzoom beside a dock is not on the render server")
            #expect(container.isLifted && grid.frontHost === p1, "p1 is not above the returning dock")
            let returning = screen.subviews
            #expect(dock.superview === screen && (returning.firstIndex(of: dock) ?? .max) < (returning.firstIndex(of: container) ?? -1),
                    "the returning dock is above the unzooming pane")
            #expect(await grid.landed(), "the unzoom did not land in 5 s")
            let landed = screen.subviews
            #expect(!container.isLifted && abs(container.frame.minX - screen.geometry.clipMinX) < 0.5,
                    "the strip container is not the strip's range: \(container.frame)")
            #expect((landed.firstIndex(of: container) ?? .max) < (landed.firstIndex(of: dock) ?? -1), "the dock is not above the strip again")
            #expect(p1.layer?.mask == nil && p1.layer?.backgroundColor == nil)
        }
    }

    /// The docked pane zooms: it is in front of the strip, whose container stays at its range under the
    /// covered panes, and the landing lets the strip's panes go.
    @Test func aDockedPaneZoomsInFrontOfTheStripOnTheRenderServer() async throws {
        try await Render.withMotion {
            let grid = Grid(renderServer: true, layout: Self.docked)
            defer { grid.close() }
            try #require(grid.window.screen != nil, "the window is on no screen: nothing animates")
            let screen = grid.screen, container = screen.stripContainer
            try #require(!screen.hasMotion, "the docked layout is not at rest")
            let chat = try grid.host("chat"), p1 = try grid.host("p1"), p2 = try grid.host("p2")
            grid.zoom("chat")
            #expect(!screen.hasMotion && screen.zoomMotion.pane == "chat" && screen.zoomMotion.rendersOnServer,
                    "the dock's zoom is not on the render server")
            #expect(Set(screen.covered) == ["p1", "p2"], "covered \(screen.covered)")
            #expect(grid.frontHost === chat && !container.isLifted, "the dock's pane is not in front of the strip")
            let order = screen.subviews
            #expect((order.firstIndex(of: container) ?? .max) < (order.firstIndex(of: chat) ?? -1), "the strip is above the zooming dock")
            #expect(await grid.landed(), "the zoom did not land in 5 s")
            #expect(screen.covered.isEmpty && p1.superview == nil && p2.superview == nil, "the strip's panes were not let go")
            #expect(chat.superview === screen && chat.layer?.backgroundColor == nil && screen.zoomMotion.pane == nil)
        }
    }
}
