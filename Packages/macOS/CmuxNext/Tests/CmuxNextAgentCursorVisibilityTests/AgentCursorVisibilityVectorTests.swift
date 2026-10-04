import CmuxNextAgentCursor
import CmuxNextAgentCursorVisibility
import CoreGraphics
import Foundation
import Testing

/// Replays schemas/agent-cursor-visibility/vectors.json: every rule of the
/// agent cursor's visibility (CURSOR-HIDDEN, CURSOR-SHOW, CURSOR-SCREENS).
@MainActor @Suite struct AgentCursorVisibilityVectorTests {
    struct Expected: Decodable, Equatable {
        var kind: String
        var window: String?
        var viewport: AgentCursorRect?
        var clip: AgentCursorRect?
        var zoom: Double?
        var anchor: String?
        var rect: AgentCursorRect?
        var reason: String?
    }

    struct Case: Decodable {
        var name: String
        var target: String
        var snapshot: AgentCursorVisibilitySnapshot
        var expect: Expected
    }

    struct Vectors: Decodable {
        var v: Int
        var cases: [Case]
    }

    static func vectors() throws -> Vectors {
        // Tests/CmuxNextAgentCursorVisibilityTests/<file> -> repository root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let file = url.appending(path: "schemas/agent-cursor-visibility/vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: file))
    }

    static func describe(_ result: AgentCursorVisibility) -> Expected {
        switch result {
        case let .visible(window, viewport, clip, zoom):
            return Expected(kind: "visible", window: window, viewport: AgentCursorRect(viewport), clip: AgentCursorRect(clip), zoom: zoom)
        case let .hidden(window, anchor, rect):
            return Expected(kind: "hidden", window: window, anchor: name(anchor), rect: AgentCursorRect(rect))
        case let .notDrawn(reason):
            return Expected(kind: "notDrawn", reason: reason.rawValue)
        }
    }

    static func name(_ anchor: AgentCursorAnchor) -> String {
        switch anchor {
        case .tabChip: "tabChip"
        case .tabStrip: "tabStrip"
        case let .columnEdge(side): "columnEdge.\(side.rawValue)"
        case .workspaceRow: "workspaceRow"
        case .windowEdge: "windowEdge"
        }
    }

    @Test func everySharedVectorResolves() throws {
        let vectors = try Self.vectors()
        #expect(vectors.v == 1)
        #expect(vectors.cases.count >= 20)
        for item in vectors.cases {
            let result = AgentCursorVisibilityResolver.resolve(target: item.target, in: item.snapshot)
            #expect(Self.describe(result) == item.expect, "\(item.name)")
        }
    }

    // MARK: Placement for one window's overlay model

    private let overlay = CGRect(x: 0, y: 0, width: 1000, height: 700)

    @Test func aVisibleTargetPlacesItsViewportOnlyInItsWindow() {
        let viewport = CGRect(x: 700, y: 72, width: 500, height: 628)
        let result = AgentCursorVisibility.visible(window: "w1", viewport: viewport, clip: viewport, zoom: 1.5)
        #expect(result.placement(forWindow: "w1", overlay: overlay) == .visible(content: viewport, magnification: 1))
        #expect(result.placement(forWindow: "w2", overlay: overlay) == .elsewhere)
    }

    @Test func aSidebarRowAnchorMovesOntoTheLeadingEdgeOfThePlane() {
        let row = CGRect(x: -240, y: 80, width: 220, height: 28)
        let result = AgentCursorVisibility.hidden(window: "w1", anchor: .workspaceRow, rect: row)
        #expect(result.placement(forWindow: "w1", overlay: overlay) == .hidden(anchor: CGRect(x: 0, y: 80, width: 0, height: 28)))
    }

    @Test func anAnchorInsideThePlaneIsKept() {
        let chip = CGRect(x: 8, y: 4, width: 110, height: 28)
        let result = AgentCursorVisibility.hidden(window: "w1", anchor: .tabChip, rect: chip)
        #expect(result.placement(forWindow: "w1", overlay: overlay) == .hidden(anchor: chip))
    }

    @Test func notDrawnIsElsewhereInEveryWindow() {
        #expect(AgentCursorVisibility.notDrawn(.minimized).placement(forWindow: "w1", overlay: overlay) == .elsewhere)
        #expect(AgentCursorVisibility.notDrawn(.otherSpace).placement(forWindow: "w1", overlay: overlay) == .elsewhere)
    }
}
