import Foundation
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Testing

/// Personal order is a hot path of every sidebar projection. It must retain daemon order for
/// unranked workspaces while walking the store's already-sorted personal projection once.
@MainActor @Suite(.serialized) struct PersonalSidebarOrderCostTests {
    private static func workspace(_ key: String) throws -> WorkspaceModel {
        let object: [String: Any] = ["id": key, "key": key, "name": key, "screens": []]
        let data = try JSONSerialization.data(withJSONObject: object)
        return WorkspaceModel(try JSONDecoder().decode(WorkspaceSnapshot.self, from: data))
    }

    @Test func rankedRowsPrecedeUnrankedRowsAndTiesKeepDaemonOrder() throws {
        let models = try ["k3", "k-unranked", "k1", "k2", "k4"].map(Self.workspace)
        let rows = [
            PersonalWorkspace(sessionID: "local", workspaceKey: WorkspaceKey(rawValue: "k1"), index: 1),
            PersonalWorkspace(sessionID: "local", workspaceKey: WorkspaceKey(rawValue: "k4"), index: 1),
            PersonalWorkspace(sessionID: "local", workspaceKey: WorkspaceKey(rawValue: "k2"), index: 0),
            PersonalWorkspace(sessionID: "remote", workspaceKey: WorkspaceKey(rawValue: "k3"), index: 0),
        ]
        let personal = PersonalStore()
        personal.workspaces = rows
        let byKey = Dictionary(rows.filter { $0.sessionID == "local" }.map { ($0.workspaceKey.rawValue, $0) },
                               uniquingKeysWith: { first, _ in first })
        let ordered = PersonalSidebar.order(models, rows: byKey, orderedRows: personal.workspacesInOrder)
        #expect(ordered.map(\.id) == ["k2", "k1", "k4", "k3", "k-unranked"])
    }

    /// A same-harness timing row for the PR's Performance table. The test deliberately repeats the
    /// 1,000-workspace projection so the before/after comparison uses one runner and one operation.
    @Test func oneThousandWorkspaceProjectionTiming() throws {
        let models = Array(try (0..<1_000).map { try Self.workspace("k\($0)") }.reversed())
        let rows = models.enumerated().map { index, model in
            PersonalWorkspace(sessionID: "local", workspaceKey: WorkspaceKey(rawValue: model.id), index: index)
        }
        let personal = PersonalStore()
        personal.workspaces = rows
        let byKey = Dictionary(rows.map { ($0.workspaceKey.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        let started = Date()
        for _ in 0..<10 {
            _ = PersonalSidebar.order(models, rows: byKey, orderedRows: personal.workspacesInOrder)
        }
        let elapsed = Date().timeIntervalSince(started) * 1_000
        print("WORKSPACE-ORDER-BENCH n=1000 runs=10 total_ms=\(String(format: \"%.2f\", elapsed)) per_pass_ms=\(String(format: \"%.2f\", elapsed / 10))")
    }
}
