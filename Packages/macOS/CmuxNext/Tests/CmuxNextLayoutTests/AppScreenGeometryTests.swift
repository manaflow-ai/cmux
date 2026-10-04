import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextLayout

/// App screens in the layout (plans/cmux-next/app-screens.md 3): an app
/// screen's column fills the viewport and draws without chrome. Default style: gap 6, no pane
/// padding, 1000 x 600 viewport, scale 2.
@Suite struct AppScreenGeometryTests {
    let viewport = CGSize(width: 1000, height: 600)
    let style = LayoutStyle()

    private func geometry(_ layout: ScreenLayout) -> ScreenGeometry {
        ScreenGeometry.compute(layout, viewport: viewport, style: style, scale: 2)
    }

    @Test func anAppColumnAloneFillsTheScreenAndNothingScrolls() {
        let layout = ScreenLayout.columns([LayoutColumn(id: "app", width: 0.3, root: .leaf("p"), app: "app-store")])
        let g = geometry(layout)
        #expect(g.panes["p"] == CGRect(origin: .zero, size: viewport))
        #expect(g.columnEdges.isEmpty)
        #expect(g.gapZones.isEmpty)
        #expect(g.maxOffset == 0)
        #expect(layout.chromelessPanes == ["p"])
    }

    /// An `app` screen never grows a column: no new-column target there.
    @Test func anAppScreenOffersNoNewColumn() {
        let layout = ScreenLayout.columns([LayoutColumn(id: "app", width: 1, root: .leaf("p"), app: "app-store")])
        let g = geometry(layout)
        let target = DropZoneGeometry.target(atView: CGPoint(x: 500, y: 300), offset: 0, screen: "s", geometry: g, style: style)
        #expect(target != .newColumn(screen: "s", after: "app"))
        #expect(g.gapZones.isEmpty)
    }

    @Test func ordinaryColumnsKeepTheirChrome() {
        let layout = ScreenLayout.columns([
            LayoutColumn(id: "c0", width: 0.3, root: .leaf("a"), dock: DockColumn(edge: .left, mode: .docked)),
            LayoutColumn(id: "c1", width: 0.5, root: .leaf("b")),
        ])
        #expect(layout.chromelessPanes.isEmpty)
        #expect(geometry(layout).panes["a"]?.minX == 6)
        #expect(ScreenLayout.splits(.leaf("x")).chromelessPanes.isEmpty)
    }

    /// Gaining or losing the app mark is a structural change (no animation
    /// between a chromed and a chromeless pane).
    @Test func theAppMarkIsStructural() {
        let plain = ScreenLayout.columns([LayoutColumn(id: "c", width: 1, root: .leaf("p"))])
        let app = ScreenLayout.columns([LayoutColumn(id: "c", width: 1, root: .leaf("p"), app: "home")])
        #expect(!plain.hasSameStructure(as: app))
        #expect(LayoutScreen(id: "s", name: "", layout: plain).kind == .workspace)
        #expect(LayoutScreenKind.app("home").app == "home")
        #expect(LayoutScreenKind.workspace.app == nil)
    }
}

extension LayoutDesignMetricsTests {
    /// With pane padding, rounding and a border on, an app screen's pane
    /// still draws edge to edge with no ring, border or rounding.
    @Test func appScreenPanesDrawWithoutChrome() async throws {
        let layout = ScreenLayout.columns([LayoutColumn(id: "app", width: 1, root: .leaf("h"), app: "app-store")])
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "", layout: layout, kind: .app("app-store"))],
                                activeScreenID: "s", focusedPane: "h")
        let provider = StubProvider()
        let view = LayoutRootView(model: model, contentProvider: provider)
        view.frame = CGRect(origin: .zero, size: CGSize(width: 1000, height: 400))
        view.layoutSubtreeIfNeeded()
        try await withPaneChrome(PaneChromeOverrides(padding: 4, cornerRadius: 6, border: .subtle)) {
            try await waitUntil { view.context.hosts["h"]?.bounds.width == 1000 }
            let host = try #require(view.context.hosts["h"])
            #expect(host.bounds.size == CGSize(width: 1000, height: 400))
            #expect(host.contentRect == host.bounds)
            #expect(host.content.superview?.layer?.cornerRadius == 0)
            #expect(!host.chrome.showsRing)
            #expect(!host.chrome.showsBorder)
        }
        withExtendedLifetime(provider) {}
    }
}
