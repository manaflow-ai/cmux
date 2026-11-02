import CmuxNextAgentCursor
import CmuxNextAgentCursorVisibility
import CoreGraphics
import Foundation
import Testing

/// Replays schemas/agent-cursor-visibility/vectors.json through the Swift
/// resolver, which encodes the snapshot, calls the Rust rules over the app
/// FFI (`agent_cursor_visibility`) and decodes the answer. The rules
/// themselves are proved in cmux-focus-core's own replay of the same file;
/// this proves the wire between the two in both directions.
struct AgentCursorVisibilityVectorTests {
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
        case let .visible(window, viewport, clip, zoom, _):
            return Expected(kind: "visible", window: window, viewport: AgentCursorRect(viewport), clip: AgentCursorRect(clip), zoom: zoom)
        case let .hidden(window, anchor, rect):
            return Expected(kind: "hidden", window: window, anchor: anchor.wireName, rect: AgentCursorRect(rect))
        case let .notDrawn(reason):
            return Expected(kind: "notDrawn", reason: reason.rawValue)
        }
    }

    @Test func everySharedVectorResolves() throws {
        let vectors = try Self.vectors()
        #expect(vectors.v == 1)
        #expect(vectors.cases.count >= 26)
        for item in vectors.cases {
            let result = AgentCursorVisibilityResolver.resolve(target: item.target, in: item.snapshot)
            #expect(Self.describe(result) == item.expect, "\(item.name)")
        }
    }

    /// A fitted page's emulation scale comes back from the rules; no scale is 1.
    @Test func aVisiblePageKeepsItsScale() throws {
        let cases = try Self.vectors().cases
        let base = try #require(cases.first(where: { $0.name == "selected_tab_visible" }))
        var snapshot = base.snapshot
        snapshot.windows[0].panes[0].page?.scale = 0.5
        let viewport = CGRect(x: 0, y: 72, width: 500, height: 628)
        #expect(AgentCursorVisibilityResolver.resolve(target: base.target, in: snapshot)
            == .visible(window: "w1", viewport: viewport, clip: viewport, zoom: 1, scale: 0.5))
        snapshot.windows[0].panes[0].page?.scale = nil
        #expect(AgentCursorVisibilityResolver.resolve(target: base.target, in: snapshot)
            == .visible(window: "w1", viewport: viewport, clip: viewport, zoom: 1, scale: 1))
    }

    @Test(arguments: [AgentCursorAnchor.tabChip, .tabStrip, .columnEdge(.leading), .columnEdge(.trailing),
                      .columnEdge(.top), .columnEdge(.bottom), .workspaceRow, .windowEdge])
    func everyAnchorNameRoundTrips(_ anchor: AgentCursorAnchor) {
        #expect(AgentCursorAnchor(wireName: anchor.wireName) == anchor)
    }

    // MARK: Placement for one window's cursor host

    @Test func aVisibleTargetPlacesItsViewportOnlyInItsWindow() {
        let viewport = CGRect(x: 700, y: 72, width: 500, height: 628)
        let result = AgentCursorVisibility.visible(window: "w1", viewport: viewport, clip: viewport, zoom: 1.5)
        #expect(result.placement(forWindow: "w1") == .visible(content: viewport, clip: viewport, zoom: 1.5, magnification: 1))
        #expect(result.placement(forWindow: "w2") == .elsewhere)
    }

    /// Window content-view space: the sidebar row anchor stays where the row
    /// is (the window-level host draws over the sidebar too).
    @Test func aSidebarRowAnchorStaysAtTheRow() {
        let row = CGRect(x: 8, y: 80, width: 224, height: 28)
        let result = AgentCursorVisibility.hidden(window: "w1", anchor: .workspaceRow, rect: row)
        #expect(result.placement(forWindow: "w1") == .hidden(anchor: row))
        let left = CGRect(x: -240, y: 80, width: 220, height: 28)
        #expect(AgentCursorVisibility.hidden(window: "w1", anchor: .workspaceRow, rect: left)
            .placement(forWindow: "w1") == .hidden(anchor: left))
    }

    @Test func notDrawnIsElsewhereInEveryWindow() {
        #expect(AgentCursorVisibility.notDrawn(.minimized).placement(forWindow: "w1") == .elsewhere)
        #expect(AgentCursorVisibility.notDrawn(.otherSpace).placement(forWindow: "w1") == .elsewhere)
    }
}
