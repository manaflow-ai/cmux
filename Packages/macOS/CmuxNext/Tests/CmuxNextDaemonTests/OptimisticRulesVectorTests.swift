import Foundation
import Testing
@testable import CmuxNextDaemon

/// The optimistic overlay's rules run in cmux-layout-reducer (`optimistic`, over the app FFI): every golden vector
/// (`cmux-tui/crates/cmux-layout-reducer/tests/data/optimistic_vectors.json`, recorded from the Swift rules and their
/// tests before they moved) answers the same view through the store's own call (``OptimisticRules/respond(_:)``).
/// The store tests (InstantCreateIntentTests, ProvisionalDockTests, NewColumnLeftTests, TabSpamRaceTests and the rest)
/// cover the records the overlay writes from those answers.
struct OptimisticRulesVectorTests {
    private static func vectors() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cmux-tui/crates/cmux-layout-reducer/tests/data/optimistic_vectors.json")
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    @Test func everyVectorAnswersItsViewOverTheAppFFI() throws {
        let cases = try Self.vectors()
        #expect(cases.count >= 55)
        for vector in cases {
            let name = vector["name"] as? String ?? "?"
            let request = try JSONSerialization.data(withJSONObject: try #require(vector["request"]))
            let answer = try #require(OptimisticRules.respond(request), "\(name): refused")
            let got = try JSONSerialization.jsonObject(with: answer, options: .fragmentsAllowed) as? NSObject
            let want = vector["response"] as? NSObject
            #expect(got == want || (want is NSNull && got is NSNull), "\(name)")
        }
    }

    /// A move in a pane while held closes keep tabs out of its visible order goes to the same place in the daemon's
    /// order (Leo 2026-11-05, the close/create shuffle), through the store's own entry point.
    @MainActor @Test func aHeldCloseLeftOfTheSlotCountsInTheStore() throws {
        let paneID = PaneID(rawValue: 3)
        let surfaces = (4...8).map { SurfaceID(rawValue: $0) }
        let store = DaemonStore()
        let workspace = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001"), name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: paneID, layout: .leaf(paneID),
                                     panes: [PaneSnapshot(id: paneID, tabs: surfaces.map { TabSnapshot(surface: $0) })])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [workspace]))
        let pane = try #require(store.pane(paneID))
        store.holdTabs([try #require(store.tab(surface: surfaces[1])).id])
        #expect(store.intendClose([surfaces[1]]) != nil)
        let moved = store.daemonMoveIndex(2, moving: surfaces[4], in: pane)
        #expect(moved.final == 3)
        #expect(moved.current == 4)
    }
}
