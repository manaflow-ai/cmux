import CmuxMobileModel
import Foundation
import Testing

// workspace_cache_save_burst: a burst of one-row workspace events (an agent working, titles moving)
// each saves the whole Workspaces cache (`LiveCoordinator.scheduleSnapshotSave` → `LiveSnapshotStore.save`).
// Before: every save re-encoded and rewrote every row (head + tail files), so a burst of E events at
// N workspaces cost E × N row encodes on the utility queue. After: writes are coalesced
// (`minimumWriteInterval`, 2 s in the app), a burst writes its first and its latest.
// One harness, both stores: the old one is `minimumWriteInterval: nil`.
// Budget: the coalesced burst writes at most 2 times, at any E, and its wall (saves through
// `flush`) stays within 3 single writes, so it is flat when the events grow 10x.
// Model check: LiveSnapshotStoreCoalescingTests (CmuxMobileModelTests).
//
// Leo, 2026-11-27: "maybe we ought to optimize our ds & a for our tooling + whatever stuff wrt the
// rendering of the app and whatnot".

extension InstantPerfTests {
    @Suite("DSA bench: Workspaces cache save burst", .serialized)
    struct WorkspaceCacheSaveBurstPerfTests {
        struct Run { var ms: Double; var writes: Int }

        static func snapshot(_ rows: [Workspace], step: Int) -> LiveSnapshot {
            var rows = rows
            let index = (step * 7919) % rows.count
            rows[index].title = "edited \(step)"
            return LiveSnapshot(teamID: "team-bench", teamName: "Bench", macs: [WorkspaceCacheFixture.mac],
                                linkedMacID: WorkspaceCacheFixture.mac.id,
                                workspaces: [WorkspaceCacheFixture.mac.id: .init(workspaces: rows, savedAt: Date(timeIntervalSince1970: Double(step)))])
        }

        static func burst(rows: [Workspace], events: Int, interval: Duration?) -> Run {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "dsa-save-burst-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = LiveSnapshotStore(directory: directory, minimumWriteInterval: interval)
            // Snapshots built untimed: the bench times the store, not the caller's copy.
            let snapshots = (0..<events).map { snapshot(rows, step: $0) }
            let elapsed = ContinuousClock().measure {
                for snapshot in snapshots { store.save(snapshot, accountID: WorkspaceCacheFixture.accountID) }
                store.flush()
            }
            return Run(ms: InstantPerfReport.ms(elapsed), writes: store.writeCount)
        }

        @Test("workspace_cache_save_burst", arguments: [500, 1_100, 5_000])
        func saveBurst(workspaces: Int) throws {
            let rows = Array(WorkspaceCacheFixture.workspaces(.god).prefix(workspaces))
            let single = Self.burst(rows: rows, events: 1, interval: nil)
            var line: [String: Any] = ["metric": "workspace_cache_save_burst", "workspaces": workspaces,
                                       "single_write_ms": (single.ms * 1_000).rounded() / 1_000]
            for events in [50, 500] {
                // The old store at 500 events and 5,000 rows is ~500 full rewrites; skip it there.
                if !(events == 500 && workspaces == 5_000) {
                    let before = Self.burst(rows: rows, events: events, interval: nil)
                    line["before_\(events)_ms"] = (before.ms * 1_000).rounded() / 1_000
                    line["before_\(events)_writes"] = before.writes
                    #expect(before.writes == events)
                }
                let after = Self.burst(rows: rows, events: events, interval: .seconds(2))
                line["after_\(events)_ms"] = (after.ms * 1_000).rounded() / 1_000
                line["after_\(events)_writes"] = after.writes
                #expect(after.writes <= 2, "\(events) events at \(workspaces) workspaces wrote \(after.writes) times")
                #expect(after.ms <= max(3 * single.ms, 5), "\(events) events: \(after.ms) ms vs one write \(single.ms) ms")
            }
            if let a = line["after_50_ms"] as? Double, let b = line["after_500_ms"] as? Double {
                line["after_10x_ratio"] = (b / max(a, 0.001) * 100).rounded() / 100
            }
            let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print("DSABENCH \(String(decoding: data, as: UTF8.self))")
        }
    }
}
