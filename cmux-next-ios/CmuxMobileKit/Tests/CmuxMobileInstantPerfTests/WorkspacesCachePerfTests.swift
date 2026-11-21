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

// Nested in `InstantPerfTests`, whose `.serialized` covers its child suites: a bench case never
// runs beside another (this target's suites would otherwise run in parallel).
extension InstantPerfTests {
    @MainActor
    @Suite("Instant list perf: Workspaces cache", .serialized)
    struct WorkspacesCachePerfTests {
        /// The cache's rows the first screen is built from, read as the coordinator reads them at launch.
        static func restoredRows(_ store: LiveSnapshotStore) -> (macs: [MacDevice], rows: [Workspace])? {
            guard let snapshot = store.loadFirstScreen(accountID: WorkspaceCacheFixture.accountID) else { return nil }
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
                // Green since the head/tail cache: the launch reads each Mac's first screen of rows (one
                // small file) and builds the inbox over those; the rest is read off the main thread.
                note: "\(WorkspaceCacheFixture.count(.small)) vs \(WorkspaceCacheFixture.count(.god)) workspaces cached for one Mac, no link; first-screen read \(Self.read(.small)) vs \(Self.read(.god))")
        }

        /// The bytes and rows the first screen read for `size`'s cache.
        static func read(_ size: InstantPerfSize) -> String {
            let (store, directory) = WorkspaceCacheFixture.store(size)
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = store.loadFirstScreen(accountID: WorkspaceCacheFixture.accountID)
            guard let read = store.lastFirstScreenRead else { return "none" }
            return "\(read.bytes) B, \(read.rows) rows"
        }
    }
}
