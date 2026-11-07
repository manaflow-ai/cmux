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
