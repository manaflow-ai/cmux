import CoreGraphics
import Foundation
import Testing
import Bonsplit
@testable import CmuxWorkspaces

@Suite("TmuxPaneOverlayGeometry")
struct TmuxPaneOverlayGeometryTests {
    private func snapshot(
        container: PixelRect,
        panes: [(id: UUID, frame: PixelRect)]
    ) -> LayoutSnapshot {
        LayoutSnapshot(
            containerFrame: container,
            panes: panes.map {
                PaneGeometry(
                    paneId: $0.id.uuidString,
                    frame: $0.frame,
                    selectedTabId: nil,
                    tabIds: []
                )
            },
            focusedPaneId: nil,
            timestamp: 0
        )
    }

    @Test("content rect trims the top chrome and clamps height to zero")
    func contentRectTrims() {
        let geometry = TmuxPaneOverlayGeometry(topChromeHeight: 28)
        let rect = geometry.contentRect(CGRect(x: 10, y: 20, width: 100, height: 200))
        #expect(rect == CGRect(x: 10, y: 48, width: 100, height: 172))

        // A pane shorter than the chrome height keeps at least 1pt of content.
        let tiny = geometry.contentRect(CGRect(x: 0, y: 0, width: 50, height: 10))
        #expect(tiny == CGRect(x: 0, y: 9, width: 50, height: 1))
    }

    @Test("workspace-local overlay rect offsets by both container axes")
    func overlayRectWorkspaceLocal() {
        let paneId = UUID()
        let snap = snapshot(
            container: PixelRect(x: 5, y: 7, width: 300, height: 400),
            panes: [(paneId, PixelRect(x: 50, y: 100, width: 120, height: 240))]
        )
        let geometry = TmuxPaneOverlayGeometry(topChromeHeight: 28)
        let rect = geometry.overlayRect(layoutSnapshot: snap, paneId: PaneID(id: paneId))
        // offset: x -5, y -7; then top inset 28.
        #expect(rect == CGRect(x: 45, y: 93 + 28, width: 120, height: 240 - 28))
    }

    @Test("window-content overlay rect preserves the container x-offset")
    func windowOverlayRectKeepsX() {
        let paneId = UUID()
        let snap = snapshot(
            container: PixelRect(x: 5, y: 7, width: 300, height: 400),
            panes: [(paneId, PixelRect(x: 50, y: 100, width: 120, height: 240))]
        )
        let geometry = TmuxPaneOverlayGeometry(topChromeHeight: 28)
        let rect = geometry.windowOverlayRect(layoutSnapshot: snap, paneId: PaneID(id: paneId))
        // x is NOT offset; y offset by -7; top inset 28.
        #expect(rect == CGRect(x: 50, y: 93 + 28, width: 120, height: 240 - 28))
    }

    @Test("missing snapshot or pane yields nil")
    func missingYieldsNil() {
        let geometry = TmuxPaneOverlayGeometry(topChromeHeight: 28)
        #expect(geometry.overlayRect(layoutSnapshot: nil, paneId: PaneID()) == nil)
        let snap = snapshot(
            container: PixelRect(x: 0, y: 0, width: 100, height: 100),
            panes: []
        )
        #expect(geometry.overlayRect(layoutSnapshot: snap, paneId: PaneID()) == nil)
        #expect(geometry.overlayRect(layoutSnapshot: snap, paneId: nil) == nil)
    }

    @Test("effective snapshot prefers a renderable live snapshot")
    func effectiveSnapshotPrefersLive() {
        let geometry = TmuxPaneOverlayGeometry(topChromeHeight: 0)
        let renderable = snapshot(
            container: PixelRect(x: 0, y: 0, width: 100, height: 100),
            panes: [(UUID(), PixelRect(x: 0, y: 0, width: 50, height: 50))]
        )
        let degenerate = snapshot(
            container: PixelRect(x: 0, y: 0, width: 0, height: 0),
            panes: []
        )
        // Live renderable wins.
        #expect(geometry.effectiveSnapshot(cachedSnapshot: degenerate, liveSnapshot: renderable) == renderable)
        // Live degenerate falls back to renderable cache.
        #expect(geometry.effectiveSnapshot(cachedSnapshot: renderable, liveSnapshot: degenerate) == renderable)
        // Both degenerate: returns cached (non-nil) per the fallback order.
        #expect(geometry.effectiveSnapshot(cachedSnapshot: degenerate, liveSnapshot: degenerate) == degenerate)
        // Nil cache with degenerate live returns the degenerate live.
        #expect(geometry.effectiveSnapshot(cachedSnapshot: nil, liveSnapshot: degenerate) == degenerate)
    }

    @Test("hasRenderableGeometry requires a non-degenerate container and pane")
    func hasRenderableGeometry() {
        let renderable = snapshot(
            container: PixelRect(x: 0, y: 0, width: 100, height: 100),
            panes: [(UUID(), PixelRect(x: 0, y: 0, width: 50, height: 50))]
        )
        #expect(TmuxPaneOverlayGeometry.hasRenderableGeometry(renderable))

        let tinyContainer = snapshot(
            container: PixelRect(x: 0, y: 0, width: 1, height: 1),
            panes: [(UUID(), PixelRect(x: 0, y: 0, width: 50, height: 50))]
        )
        #expect(!TmuxPaneOverlayGeometry.hasRenderableGeometry(tinyContainer))

        let tinyPanes = snapshot(
            container: PixelRect(x: 0, y: 0, width: 100, height: 100),
            panes: [(UUID(), PixelRect(x: 0, y: 0, width: 1, height: 1))]
        )
        #expect(!TmuxPaneOverlayGeometry.hasRenderableGeometry(tinyPanes))
    }
}

@Suite("TmuxPaneLayoutReport")
struct TmuxPaneLayoutReportTests {
    @Test("activePane prefers the active pane, falls back to first")
    func activePane() {
        let a = TmuxPaneLayoutPane(paneId: "a", left: 0, top: 0, width: 10, height: 10, isActive: false)
        let b = TmuxPaneLayoutPane(paneId: "b", left: 10, top: 0, width: 10, height: 10, isActive: true)
        #expect(TmuxPaneLayoutReport(panes: [a, b]).activePane == b)
        #expect(TmuxPaneLayoutReport(panes: [a]).activePane == a)
        #expect(TmuxPaneLayoutReport(panes: []).activePane == nil)
    }

    @Test("overlayRect scales by cell size and offsets by surface origin")
    func overlayRect() {
        let pane = TmuxPaneLayoutPane(paneId: "a", left: 2, top: 3, width: 4, height: 5, isActive: true)
        let rect = pane.overlayRect(
            surfaceFrame: CGRect(x: 100, y: 200, width: 999, height: 999),
            cellSize: CGSize(width: 8, height: 16)
        )
        #expect(rect == CGRect(x: 100 + 16, y: 200 + 48, width: 32, height: 80))
    }

    @Test("overlayRect returns nil for degenerate cell sizes or panes")
    func overlayRectNil() {
        let pane = TmuxPaneLayoutPane(paneId: "a", left: 0, top: 0, width: 4, height: 5, isActive: true)
        #expect(pane.overlayRect(surfaceFrame: .zero, cellSize: CGSize(width: 0, height: 16)) == nil)
        let zeroPane = TmuxPaneLayoutPane(paneId: "a", left: 0, top: 0, width: 0, height: 5, isActive: true)
        #expect(zeroPane.overlayRect(surfaceFrame: .zero, cellSize: CGSize(width: 8, height: 16)) == nil)
    }
}
