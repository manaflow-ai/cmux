@testable import CmuxMobileLive
import CmuxMobileModel
import Foundation
import Testing

// snapshot_save_gate: what `LiveCoordinator.saveSnapshot` costs on the main actor for a workspace
// event that changed nothing it reads (a row the phone's model deduped, a link state that left the
// live Macs as they were). Before: the whole-list build (a filter per Mac, a compare of every row).
// After: `SnapshotSaveGate`'s key compare, O(Macs). One harness, 1,100 and 11,000 workspaces over 3 Macs.
// Budget: the gated event ≤ 0.05 ms at both sizes (flat at 10x).
// Model check: SnapshotSaveGateTests (CmuxMobileLiveTests).
//
// Leo, 2026-11-27: "maybe we ought to optimize our ds & a for our tooling + whatever stuff wrt the
// rendering of the app and whatnot".

extension InstantPerfTests {
    @MainActor
    @Suite("DSA bench: snapshot save gate", .serialized)
    struct SnapshotSaveGatePerfTests {
        @Test("snapshot_save_gate")
        func gate() throws {
            let macs = ["m1", "m2", "m3"].map { MacDevice(id: $0, name: $0, isOnline: true) }
            let team = Team(id: "t", name: "T", macs: macs)
            var line: [String: Any] = ["metric": "snapshot_save_gate"]
            var after: [Int: Double] = [:]
            for count in [1_100, 11_000] {
                let base = WorkspaceCacheFixture.workspaces(.god)
                let rows = (0..<count).map { i -> Workspace in
                    var ws = base[i % base.count]
                    ws = Workspace(id: "w\(i)", macID: macs[i % 3].id, title: ws.title, directory: ws.directory, branch: ws.branch,
                                   tabs: ws.tabs, lastActivityAt: ws.lastActivityAt)
                    return ws
                }
                let live = macs.map(\.id), now = Date()
                let isPending = { (_: String) in false }
                let snapshot = LiveCoordinator.snapshotToSave(team: team, workspaces: rows, isPending: isPending, liveMacIDs: live,
                                                              linkedMacID: "m1", previous: nil, now: now, stampInterval: 60)
                let key = SnapshotSaveGate.Key(team: team, workspacesRevision: 7, pending: [], liveMacIDs: live,
                                               linkedMacID: "m1", snapshotGeneration: 1)
                var gate = SnapshotSaveGate()
                gate.saved(key, generation: 1)
                let events = 200
                var rebuilt = 0
                let before = ContinuousClock().measure {
                    for _ in 0..<events {
                        let next = LiveCoordinator.snapshotToSave(team: team, workspaces: rows, isPending: isPending, liveMacIDs: live,
                                                                  linkedMacID: "m1", previous: snapshot, now: now, stampInterval: 60)
                        if next != snapshot { rebuilt += 1 }
                    }
                }
                var skipped = 0
                let gated = ContinuousClock().measure {
                    for _ in 0..<events where gate.unchanged(key, snapshot: snapshot, now: now, stampInterval: 60) { skipped += 1 }
                }
                #expect(rebuilt == 0 && skipped == events)
                let b = InstantPerfReport.ms(before) / Double(events), a = InstantPerfReport.ms(gated) / Double(events)
                line["before_\(count)_ms_per_event"] = (b * 10_000).rounded() / 10_000
                line["after_\(count)_ms_per_event"] = (a * 10_000).rounded() / 10_000
                after[count] = a
                #expect(a <= 0.05, "gated event at \(count) workspaces: \(a) ms")
            }
            line["after_10x_ratio"] = ((after[11_000] ?? 0) / max(after[1_100] ?? 0, 0.000_1) * 100).rounded() / 100
            let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            print("DSABENCH \(String(decoding: data, as: UTF8.self))")
        }
    }
}
