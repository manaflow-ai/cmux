import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The page's floating glass drawn by the App under the page (AgentPaneHostGlass.swift,
/// AgentPaneView+HostGlass.swift; Leo, 2026-11-06: "why the fuck is this not glass? Like the way the
/// native menus are"). The report decodes and refuses bad ones, each surface gets the App's own glass
/// under the page at its box, and the glass goes with the surface and with the page.
@Suite(.serialized, .closesItsWindows)
@MainActor
struct AgentPaneHostGlassTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private static func request(_ surfaces: Any) -> AgentPaneRequest {
        AgentPaneRequest(body: ["id": "g", "method": "pane.glass", "params": ["surfaces": surfaces]])
    }

    private static let box: [String: Any] = [
        "id": "g1", "level": "popover", "left": 40, "top": 60, "right": 240, "bottom": 180, "radius": 12, "opacity": 0.5,
    ]

    @Test func reportsDecodeAndBadOnesAreRefused() {
        #expect(Self.request([Self.box]) == .hostGlass([
            AgentPaneHostGlassSurface(id: "g1", level: .popover, rect: CGRect(x: 40, y: 60, width: 200, height: 120),
                                      radius: 12, opacity: 0.5),
        ]))
        #expect(String(describing: Self.request([Self.box])) == "hostGlass")
        #expect(Self.request([]) == .hostGlass([]))
        #expect(AgentPageOps.methods.values.contains("pane.glass"))
        var unknownLevel = Self.box
        unknownLevel["level"] = "frosted"
        var docked = Self.box
        docked["level"] = "chrome"
        var inverted = Self.box
        inverted["right"] = 10
        var brighter = Self.box
        brighter["opacity"] = 2
        var longId = Self.box
        longId["id"] = String(repeating: "x", count: 33)
        let tooMany = (0..<17).map { index -> [String: Any] in
            var entry = Self.box
            entry["id"] = "g\(index)"
            return entry
        }
        for bad: Any in [[unknownLevel], [docked], [inverted], [brighter], [longId], [Self.box, Self.box], tooMany, "x"] {
            #expect(Self.request(bad) == .unsupported("pane.glass"))
        }
    }

    /// A dialog asks for the native dialog card's neutral glass by role (`data-host-glass-role`); an
    /// unknown role or one that is not a name is refused with the report.
    @Test func aSurfaceMayAskForADialogsGlassByRole() {
        var dialog = Self.box
        dialog["role"] = "sheet"
        #expect(Self.request([dialog]) == .hostGlass([
            AgentPaneHostGlassSurface(id: "g1", level: .popover, role: .sheet, rect: CGRect(x: 40, y: 60, width: 200, height: 120),
                                      radius: 12, opacity: 0.5),
        ]))
        var unknown = Self.box
        unknown["role"] = "menu-bar"
        var number = Self.box
        number["role"] = 3
        for bad in [unknown, number] {
            #expect(Self.request([bad]) == .unsupported("pane.glass"))
        }
    }

    @Test func eachLevelDrawsItsOverlayRolesGlass() {
        #expect(AgentPaneView.hostGlassRole(.popover) == .popover)
        #expect(AgentPaneView.hostGlassRole(.menu) == .menu)
        #expect(AgentPaneView.hostGlassRole(.chip) == .tooltip)
    }

    /// A reported surface gets an App glass surface under the page, at its box, radius and opacity;
    /// it moves with the next report and goes with the surface, and a reload clears it.
    @Test func aReportedSurfaceGetsTheAppsGlassUnderThePage() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file)))
        defer { view.close() }
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutSubtreeIfNeeded()
        let pageView: NSView = view.page ?? view.webView
        let surface = AgentPaneHostGlassSurface(id: "g1", level: .popover, rect: CGRect(x: 40, y: 60, width: 200, height: 120),
                                                radius: 12, opacity: 0.5)
        let reply = await view.model.respond(to: .hostGlass([surface]))
        #expect(reply["ok"] as? Bool == true)
        let container = try #require(view.model.hostGlass.container)
        let glass = try #require(view.model.hostGlass.views["g1"])
        // Under the page, so its see-through pixels show the glass and its content draws on top.
        let order = view.subviews
        let below = try #require(order.firstIndex { $0 === container })
        let page = try #require(order.firstIndex { $0 === pageView })
        #expect(below < page)
        #expect(container.frame == pageView.frame)
        #expect(container.hitTest(CGPoint(x: 50, y: 70)) == nil)
        let expected = AgentPaneView.hostGlassFrame(surface.rect, page: CGRect(origin: .zero, size: container.frame.size),
                                                    zoom: 1, flipped: container.isFlipped)
        #expect(glass.frame == expected)
        #expect(glass.cornerRadius == 12)
        #expect(glass.alphaValue == 0.5)
        #expect(!glass.isInteractive)

        // It follows the surface as it moves.
        var moved = surface
        moved.rect = CGRect(x: 100, y: 200, width: 200, height: 120)
        moved.opacity = 1
        _ = await view.model.respond(to: .hostGlass([moved]))
        #expect(view.model.hostGlass.views["g1"] === glass)
        #expect(glass.frame.minX == 100)
        #expect(glass.alphaValue == 1)

        // Another surface replaces it: the first one's glass goes.
        let menu = AgentPaneHostGlassSurface(id: "g2", level: .menu, rect: CGRect(x: 10, y: 10, width: 120, height: 80))
        _ = await view.model.respond(to: .hostGlass([menu]))
        #expect(view.model.hostGlass.views["g1"] == nil)
        #expect(glass.superview == nil)
        #expect(view.model.hostGlass.views["g2"] != nil)

        // The page loaded again: nothing of the old page's glass stays.
        view.model.hostGlass.pageLoaded()
        #expect(view.model.hostGlass.views.isEmpty)
        #expect(view.model.hostGlass.container == nil)
        #expect(container.superview == nil)
    }

    /// The report's zoom places the glass, never the pane's own (cmux#42413 switched host glass off
    /// for this; Leo, 2026-11-20: "we have glass project / i add background / it refract / boom done").
    /// A Chromium page applies a new zoom over another channel than its reports: a box measured at
    /// 1.5 still lands at 1.5 while the pane already set 1.25, and a pane resize keeps it there.
    @Test func theReportsZoomPlacesTheGlassAtEveryZoomAndAfterAResize() async throws {
        var withZoom = Self.box
        withZoom["id"] = "g1"
        let decoded = AgentPaneRequest(body: ["id": "g", "method": "pane.glass",
                                              "params": ["surfaces": [withZoom], "zoom": 1.25]])
        #expect(decoded == .hostGlass([
            AgentPaneHostGlassSurface(id: "g1", level: .popover, rect: CGRect(x: 40, y: 60, width: 200, height: 120),
                                      radius: 12, opacity: 0.5, zoom: 1.25),
        ]))
        for bad: Any in [0, -1, 40, "1.25", Double.nan] {
            let request = AgentPaneRequest(body: ["id": "g", "method": "pane.glass",
                                                  "params": ["surfaces": [withZoom], "zoom": bad]])
            #expect(request == .unsupported("pane.glass"))
        }

        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file)))
        defer { view.close() }
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutSubtreeIfNeeded()
        let paneZoom = CGFloat(view.uiPointerPageZoom)
        for zoom: CGFloat in [0.9, 1, 1.25, 1.5] {
            let surface = AgentPaneHostGlassSurface(id: "g1", rect: CGRect(x: 40, y: 60, width: 200, height: 120),
                                                    radius: 12, zoom: zoom)
            _ = await view.model.respond(to: .hostGlass([surface]))
            let container = try #require(view.model.hostGlass.container)
            let glass = try #require(view.model.hostGlass.views["g1"])
            let page = CGRect(origin: .zero, size: container.frame.size)
            #expect(surface.placementZoom(paneZoom: paneZoom) == zoom)
            #expect(glass.frame == AgentPaneView.hostGlassFrame(surface.rect, page: page, zoom: zoom, flipped: container.isFlipped))
            #expect(abs(glass.frame.width - 200 * zoom) < 0.001)
            #expect(abs(glass.frame.height - 120 * zoom) < 0.001)
            #expect(abs(glass.frame.minX - 40 * zoom) < 0.001)
            #expect(glass.cornerRadius == 12 * zoom)

            // A pane resize lays the glass out again at the report's zoom, under the page's new frame.
            view.frame = CGRect(x: 0, y: 0, width: 640, height: 520)
            view.layoutSubtreeIfNeeded()
            let resized = CGRect(origin: .zero, size: container.frame.size)
            #expect(container.frame == (view.page ?? view.webView).frame)
            #expect(glass.frame == AgentPaneView.hostGlassFrame(surface.rect, page: resized, zoom: zoom, flipped: container.isFlipped))
            view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
            view.layoutSubtreeIfNeeded()
        }
        // An older page that sends no zoom: the pane's own.
        let legacy = AgentPaneHostGlassSurface(id: "g1", rect: CGRect(x: 40, y: 60, width: 200, height: 120))
        #expect(legacy.placementZoom(paneZoom: 1.25) == 1.25)
    }

    /// The page's frame moved (a pane resize): the glass follows in the same layout.
    @Test func theGlassFollowsThePageFrame() async throws {
        let file = try #require(AgentPageTestRoot.page)
        let view = try #require(AgentPaneView(model: AgentPaneModel(host: NoHost(), sessionId: "session-a"), source: .bundled(file)))
        defer { view.close() }
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        view.layoutSubtreeIfNeeded()
        _ = await view.model.respond(to: .hostGlass([
            AgentPaneHostGlassSurface(id: "g1", rect: CGRect(x: 40, y: 60, width: 200, height: 120)),
        ]))
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        view.layoutSubtreeIfNeeded()
        let pageView: NSView = view.page ?? view.webView
        #expect(view.model.hostGlass.container?.frame == pageView.frame)
    }
}
