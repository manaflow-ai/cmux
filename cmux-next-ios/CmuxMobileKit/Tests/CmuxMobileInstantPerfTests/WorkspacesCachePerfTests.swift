import CmuxMobileModel
import CmuxMobileWorkspaces
import Foundation
import Testing

// f. workspaces_cold_paint_from_cache  a cold launch with no link: the Workspaces list's cache read
//                                      from disk (what `LiveCoordinator.restoreSnapshot` reads on
//                                      the main actor) to the inbox the first screen draws
//                                      (`WorkspaceInbox` over the restored rows, marked cached).
//                                      20 vs 5,000 workspaces. 16 ms (one frame).
//
// Leo, 2026-11-10: "it should just be like, okay, we load, like, nigh instantly. You can just see
// what's on your thing." Docs: cmux-next-ios/design/instant-perf.md.

@MainActor
@Suite("Instant list perf: Workspaces cache", .serialized)
struct WorkspacesCachePerfTests {
    /// The cache's rows the first screen is built from, read as the coordinator reads them at launch.
    static func restoredRows(_ store: LiveSnapshotStore) -> (macs: [MacDevice], rows: [Workspace])? {
        guard let snapshot = store.load(accountID: WorkspaceCacheFixture.accountID) else { return nil }
        return (snapshot.macs, snapshot.macs.flatMap { snapshot.workspaces[$0.id]?.workspaces ?? [] })
    }

    /// What the list draws first: the inbox over the restored rows, every Mac's list cached and its link connecting.
    static func firstScreen(_ store: LiveSnapshotStore) -> WorkspaceInbox? {
        guard let (macs, rows) = restoredRows(store) else { return nil }
        let phases = Dictionary(uniqueKeysWithValues: macs.map { ($0.id, MacDataMachine.Phase.cached(.connecting)) })
        return WorkspaceInbox(scope: .all, macs: macs, workspaces: rows, context: .init(phases: phases))
    }

    @Test("workspaces_cold_paint_from_cache")
    func coldPaintFromCache() async throws {
        func paint(_ size: InstantPerfSize) async throws -> [Double] {
            let (store, directory) = WorkspaceCacheFixture.store(size)
            defer { try? FileManager.default.removeItem(at: directory) }
            return try await InstantPerfReport.sample {
                var inbox: WorkspaceInbox?
                let elapsed = ContinuousClock().measure { inbox = Self.firstScreen(store) }
                let shown = try #require(inbox, "the cache did not restore")
                let first = shown.pinned.count + shown.recent.count
                #expect(first >= min(WorkspaceCacheFixture.count(size), 20), "the first screen lost rows: \(first)")
                #expect(shown.pinned.first?.id == "ws-0", "the first row is not the Mac's first pinned workspace")
                return elapsed
            }
        }
        let small = try await paint(.small)
        let god = try await paint(.god)
        InstantPerfReport.record(
            "workspaces_cold_paint_from_cache", target: 16, small: small, god: god,
            knownRed: [.godBudget, .ratio],
            why: "the launch decodes the whole saved list (every workspace, tab and screen) and builds the inbox over all of it before the first frame",
            note: "\(WorkspaceCacheFixture.count(.small)) vs \(WorkspaceCacheFixture.count(.god)) workspaces cached for one Mac, no link")
    }
}
