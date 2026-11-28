import CmuxNextDesign
@testable import CmuxNextPages
import Foundation
import Testing

/// RFD 0207, "Host glass for pages": every page may report its marked floating surfaces with
/// `cmux.app.glass`, decoded as the agent pane's `pane.glass` is, and the page view draws the App's
/// glass under them. A bad report is refused; no report, no layer.
@MainActor
struct PageHostGlassTests {
    static let descriptor = PageDescriptor(id: "cmux.glass-test", resource: "glass-test", namespaces: ["cmux.glass-test."])

    @Test func aReportDecodesToTheAgentPanesSurfaces() throws {
        let surfaces = try #require(PageHostGlassSurface.decode(
            [["id": "g1", "level": "menu", "left": 10, "top": 20, "right": 110, "bottom": 80, "radius": 8, "opacity": 0.5],
             ["id": "g2", "level": "popover", "role": "sheet", "left": 0, "top": 0, "right": 40, "bottom": 40]],
            zoom: 1.25))
        #expect(surfaces == [
            PageHostGlassSurface(id: "g1", level: .menu, rect: CGRect(x: 10, y: 20, width: 100, height: 60),
                                 radius: 8, opacity: 0.5, zoom: 1.25),
            PageHostGlassSurface(id: "g2", level: .popover, role: .sheet, rect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                 zoom: 1.25),
        ])
    }

    @Test func aBadReportIsRefused() {
        let box: [String: Any] = ["id": "g1", "level": "popover", "left": 0, "top": 0, "right": 10, "bottom": 10]
        #expect(PageHostGlassSurface.decode([box, box]) == nil) // a repeated id
        #expect(PageHostGlassSurface.decode([box.merging(["level": "chrome"]) { $1 }]) == nil) // docked glass
        #expect(PageHostGlassSurface.decode([box.merging(["role": "dock"]) { $1 }]) == nil) // an unknown role
        #expect(PageHostGlassSurface.decode([box.merging(["right": -5]) { $1 }]) == nil) // inside out
        #expect(PageHostGlassSurface.decode([box], zoom: 40) == nil) // a zoom past its range
        let many = (0...PageHostGlassSurface.maximum).map { box.merging(["id": "g\($0)"]) { $1 } }
        #expect(PageHostGlassSurface.decode(many) == nil)
    }

    @Test func theRouterServesTheOpToThePageView() async {
        let router = PageRouter(descriptor: Self.descriptor, routes: [])
        var drawn: [PageHostGlassSurface] = []
        router.hostGlass = { drawn = $0 }
        let reply = await router.handle(["t": "call", "id": 1, "op": PageNativeOp.hostGlass, "params": [
            "surfaces": [["id": "g1", "level": "chip", "left": 4, "top": 4, "right": 64, "bottom": 28]], "zoom": 1,
        ]])
        #expect(reply["t"]?.stringValue == "ok")
        #expect(reply["value"]?["drawn"]?.doubleValue == 1)
        #expect(drawn.map(\.id) == ["g1"])

        let bad = await router.handle(["t": "call", "id": 2, "op": PageNativeOp.hostGlass, "params": ["surfaces": "no"]])
        #expect(bad["t"]?.stringValue == "err")
        #expect(drawn.map(\.id) == ["g1"])
    }

    @Test func theLayerPlacesEachBoxAtItsZoomAndDropsTheGoneOnes() {
        let layer = PageHostGlassLayer(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        layer.apply([
            PageHostGlassSurface(id: "g1", rect: CGRect(x: 10, y: 20, width: 100, height: 50), radius: 8, zoom: 2),
            PageHostGlassSurface(id: "g2", level: .menu, rect: CGRect(x: 0, y: 0, width: 30, height: 30)),
        ], paneZoom: 1.5)
        #expect(layer.views.count == 2)
        #expect(layer.views["g1"]?.view.frame == CGRect(x: 20, y: 40, width: 200, height: 100))
        #expect(layer.views["g1"]?.view.cornerRadius == 16)
        // A page that sends no zoom is placed at the view's.
        #expect(layer.views["g2"]?.view.frame == CGRect(x: 0, y: 0, width: 45, height: 45))

        layer.apply([PageHostGlassSurface(id: "g2", level: .menu, rect: CGRect(x: 0, y: 0, width: 30, height: 30), zoom: 1)],
                    paneZoom: 1)
        #expect(layer.views.keys.sorted() == ["g2"])
        #expect(layer.subviews.count == 1)
        #expect(layer.hitTest(CGPoint(x: 5, y: 5)) == nil)
    }
}
