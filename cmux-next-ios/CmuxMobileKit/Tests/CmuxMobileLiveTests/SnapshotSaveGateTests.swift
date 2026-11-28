import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

// Model check for `SnapshotSaveGate`: on random event sequences (row edits, no-op events, pending
// rows, Macs going live or not, the focused Mac moving, time passing past the stamp interval), the
// gated save produces exactly the snapshots the old save (always build) produced.
// Bench: `snapshot_save_gate` (CmuxMobileInstantPerfTests).

@MainActor @Suite struct SnapshotSaveGateTests {
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    }

    @Test(arguments: 0..<60)
    func gatedSavesEqualAlwaysBuilding(seed: Int) {
        var rng = Rng(state: UInt64(seed) &* 0x9E37_79B9 &+ 1)
        let macs = ["m1", "m2", "m3"].map { MacDevice(id: $0, name: $0, isOnline: true) }
        let team = Team(id: "t", name: "T", macs: macs)
        var workspaces = (0..<30).map { i in
            Workspace(id: "w\(i)", macID: macs[i % 3].id, title: "w\(i)", directory: "~", tabs: [],
                      lastActivityAt: Date(timeIntervalSince1970: Double(i)))
        }
        var revision = 0, pending: Set<String> = [], live: Set<String> = ["m1"], focused: String? = "m1"
        var now = Date(timeIntervalSince1970: 1_000_000)
        // Old: always build. New: the gate, keyed with a generation that moves when the snapshot is set.
        var old: LiveSnapshot?, new: LiveSnapshot?, generation = 0
        var gate = SnapshotSaveGate()
        for step in 0..<200 {
            switch rng.int(0...9) {
            case 0, 1:
                let i = rng.int(0...29)
                workspaces[i].title = "w\(i) \(step)"
                revision += 1
            case 2:
                let id = "w\(rng.int(0...29))"
                if pending.contains(id) { pending.remove(id) } else { pending.insert(id) }
            case 3:
                let id = macs[rng.int(0...2)].id
                if live.contains(id) { live.remove(id) } else { live.insert(id) }
            case 4: focused = rng.int(0...3) == 0 ? nil : macs[rng.int(0...2)].id
            case 5: now += Double(rng.int(1...45))
            default: break // a row event the phone's model did not change
            }
            let liveIDs = macs.map(\.id).filter(live.contains)
            let isPending = { (id: String) in pending.contains(id) }

            let builtOld = LiveCoordinator.snapshotToSave(team: team, workspaces: workspaces, isPending: isPending, liveMacIDs: liveIDs,
                                                          linkedMacID: focused ?? old?.linkedMacID, previous: old, now: now,
                                                          stampInterval: LiveCoordinator.snapshotStampInterval)
            if builtOld != old { old = builtOld }

            let key = SnapshotSaveGate.Key(team: team, workspacesRevision: revision, pending: pending, liveMacIDs: liveIDs,
                                           linkedMacID: focused ?? new?.linkedMacID, snapshotGeneration: generation)
            if !gate.unchanged(key, snapshot: new, now: now, stampInterval: LiveCoordinator.snapshotStampInterval) {
                let built = LiveCoordinator.snapshotToSave(team: team, workspaces: workspaces, isPending: isPending, liveMacIDs: liveIDs,
                                                           linkedMacID: key.linkedMacID, previous: new, now: now,
                                                           stampInterval: LiveCoordinator.snapshotStampInterval)
                if built != new { new = built; generation += 1 }
                gate.saved(key, generation: generation)
            }
            #expect(new == old, "seed \(seed) step \(step)")
        }
    }
}
