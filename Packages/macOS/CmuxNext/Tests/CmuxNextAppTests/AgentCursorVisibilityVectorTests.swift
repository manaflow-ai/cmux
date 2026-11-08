import CCmuxLayoutReducerFFI
import CmuxNextAgentCursor
@testable import CmuxNextAgentCursorVisibility
import CoreGraphics
import Foundation
import Testing

/// Replays schemas/agent-cursor-visibility/vectors.json through the Swift
/// resolver, which numbers the snapshot's ids, calls the Rust rules through
/// the typed app FFI call (`cmux_agent_cursor_visibility`, cmux-focus-core)
/// and reads the answer back. The rules themselves are proved in
/// cmux-focus-core's own replay of the same file; this proves the boundary
/// in both directions.
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
        // Tests/CmuxNextAppTests/<file> -> repository root.
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
        #expect(vectors.cases.count >= 27)
        for item in vectors.cases {
            let result = AgentCursorVisibilityResolver.resolve(target: item.target, in: item.snapshot)
            #expect(Self.describe(result) == item.expect, "\(item.name)")
        }
    }

    /// A kept resolver refills its arrays on each resolve: every vector, in
    /// order and then reversed, gets its own answer, never a part of the last
    /// snapshot (more windows, panes or ids before, fewer after).
    @Test func aKeptResolverGivesEachSnapshotItsOwnAnswer() throws {
        let cases = try Self.vectors().cases
        var resolver = AgentCursorVisibilityResolver()
        for item in cases + cases.reversed() {
            let result = resolver.resolve(target: item.target, in: item.snapshot)
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

    /// Non-finite numbers (a converted `CGRect.null`, an infinite scale) keep the result the Swift
    /// rules gave them before the move: they cross the wire as strings, which JSON allows.
    @Test func nonFiniteNumbersKeepTheirResult() throws {
        let cases = try Self.vectors().cases
        func named(_ name: String) throws -> Case { try #require(cases.first(where: { $0.name == name })) }
        func resolve(_ item: Case) -> AgentCursorVisibility {
            AgentCursorVisibilityResolver.resolve(target: item.target, in: item.snapshot)
        }
        let null = AgentCursorRect(x: .infinity, y: .infinity, w: 0, h: 0)

        var chip = try named("background_tab_points_at_its_chip")
        chip.snapshot.windows[0].panes[0].chips["tab-a"] = null
        #expect(resolve(chip) == .hidden(window: "w1", anchor: .tabStrip, rect: CGRect(x: 0, y: 0, width: 500, height: 36)))

        var row = try named("other_workspace_same_window_points_at_sidebar_row")
        row.snapshot.windows[0].sidebarRows["ws1"] = null
        #expect(resolve(row) == .hidden(window: "w1", anchor: .workspaceRow, rect: null.cgRect))

        var edge = try named("target_pane_missing_points_at_window_edge")
        edge.snapshot.windows[0].overlay = null
        #expect(resolve(edge) == .hidden(window: "w1", anchor: .windowEdge,
                                         rect: CGRect(x: CGFloat.infinity, y: .infinity, width: 4, height: 0)))

        var page = try named("selected_tab_visible")
        page.snapshot.windows[0].panes[0].page?.scale = .infinity
        let viewport = CGRect(x: 0, y: 72, width: 500, height: 628)
        #expect(resolve(page) == .visible(window: "w1", viewport: viewport, clip: viewport, zoom: 1, scale: .infinity))
    }

    /// The anchor and reason numbers are written by hand in Swift and in the C
    /// header: every case maps to the header constant of its name, both ways, so
    /// a number that drifts fails here instead of the user's cursor.
    @Test func everyAnchorAndReasonIsItsHeaderConstant() {
        let anchors: [(AgentCursorAnchor, UInt32)] = [
            (.tabChip, CMUX_CURSOR_ANCHOR_TAB_CHIP),
            (.tabStrip, CMUX_CURSOR_ANCHOR_TAB_STRIP),
            (.columnEdge(.leading), CMUX_CURSOR_ANCHOR_COLUMN_EDGE_LEADING),
            (.columnEdge(.trailing), CMUX_CURSOR_ANCHOR_COLUMN_EDGE_TRAILING),
            (.columnEdge(.top), CMUX_CURSOR_ANCHOR_COLUMN_EDGE_TOP),
            (.columnEdge(.bottom), CMUX_CURSOR_ANCHOR_COLUMN_EDGE_BOTTOM),
            (.workspaceRow, CMUX_CURSOR_ANCHOR_WORKSPACE_ROW),
            (.windowEdge, CMUX_CURSOR_ANCHOR_WINDOW_EDGE),
        ]
        for (anchor, number) in anchors {
            #expect(anchor.ffiNumber == number, "\(anchor)")
            #expect(AgentCursorAnchor(ffiNumber: number) == anchor, "\(number)")
        }
        #expect(Set(anchors.map(\.1)).count == anchors.count, "anchor numbers are distinct")
        #expect(AgentCursorAnchor(ffiNumber: 8) == nil)
        let reasons: [(AgentCursorNotDrawnReason, UInt32)] = [
            (.tabClosed, CMUX_CURSOR_REASON_TAB_CLOSED),
            (.notInAnyWindow, CMUX_CURSOR_REASON_NOT_IN_ANY_WINDOW),
            (.minimized, CMUX_CURSOR_REASON_MINIMIZED),
            (.otherSpace, CMUX_CURSOR_REASON_OTHER_SPACE),
        ]
        for (reason, number) in reasons {
            #expect(reason.ffiNumber == number, "\(reason)")
            #expect(AgentCursorNotDrawnReason(ffiNumber: number) == reason, "\(number)")
        }
        #expect(Set(reasons.map(\.1)).count == reasons.count, "reason numbers are distinct")
        #expect(AgentCursorNotDrawnReason(ffiNumber: 4) == nil)
    }

    /// The vectors reach every anchor through the Swift call (a case no vector
    /// produces is only read, not tested).
    @Test func theVectorsProduceEveryAnchor() throws {
        var seen = Set<String>()
        for item in try Self.vectors().cases {
            if case let .hidden(_, anchor, _) = AgentCursorVisibilityResolver.resolve(target: item.target, in: item.snapshot) {
                seen.insert(anchor.wireName)
            }
        }
        #expect(seen == ["tabChip", "tabStrip", "columnEdge.leading", "columnEdge.trailing", "columnEdge.top",
                         "columnEdge.bottom", "workspaceRow", "windowEdge"])
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
