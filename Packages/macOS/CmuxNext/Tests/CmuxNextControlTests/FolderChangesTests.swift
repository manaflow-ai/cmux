import CmuxNextWakeups
import Foundation
import Testing

/// A folder that does not exist yet is watched through a parent, and the parent's own changes are
/// not the folder's (review of the wallpaper store: a missing Backgrounds folder was watched
/// through the app's Application Support folder, so every prompt the app saved there rebuilt the
/// wallpaper catalog). The stand-in's write is dropped and counted; the folder's creation and the
/// folder's own changes yield.
@Suite(.serialized, .timeLimit(.minutes(1))) struct FolderChangesTests {
    /// Waits (bounded, 5 s) for the ledger to count `reason` at least `count` times.
    private func waitFor(_ ledger: WakeupLedger, _ reason: String, count: UInt64) async throws {
        for _ in 0..<500 {
            if (ledger.snapshot().first { $0.owner == "FolderChanges" && $0.reason == reason }?.count ?? 0) >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the watch did not count \(count) \(reason) wakes in 5 s")
    }

    @Test func aStandInsOwnWriteYieldsNothingAndTheFolderItselfDoes() async throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("folder-changes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let missing = parent.appendingPathComponent("Backgrounds", isDirectory: true)
        let ledger = WakeupLedger()
        var changes = FolderChanges(folders: [missing], ledger: ledger).events().makeAsyncIterator()
        // Let the watch arm before the first write (the loop task opens it when it starts).
        try await Task.sleep(for: .milliseconds(100))

        // The app saves its own file next to the missing folder.
        try Data("{}".utf8).write(to: parent.appendingPathComponent("unsent-prompts.json"), options: .atomic)
        try await waitFor(ledger, "stand-in", count: 1)

        // The folder is made: one element, and the watch moves down to it.
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
        #expect(await changes.next() != nil)
        // An image the person adds in it: one more element.
        try Data([0]).write(to: missing.appendingPathComponent("mine.png"))
        #expect(await changes.next() != nil)
        #expect((ledger.snapshot().first { $0.owner == "FolderChanges" && $0.reason == "change" }?.count ?? 0) >= 2)
    }

    /// p14-energy-127: with a coalescing wait, a burst another app writes (50 files) is one element, after a
    /// flexible timer; Energy Saver stretches the wait 4 times.
    @Test func aBurstIsOneElementAfterTheCoalescingWait() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("folder-burst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ledger = WakeupLedger()
        let watch = FolderChanges(folders: [folder], coalesce: .milliseconds(500), ledger: ledger)
        var changes = watch.events().makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(100))

        for index in 0..<50 {
            try Data([UInt8(index)]).write(to: folder.appendingPathComponent("synced-\(index).png"))
        }
        #expect(await changes.next() != nil)
        // Longer than the wait again: the burst made no second element.
        try await Task.sleep(for: .milliseconds(800))
        #expect((ledger.snapshot().first { $0.owner == "FolderChanges" && $0.reason == "change" }?.count ?? 0) == 1)
        #expect((ledger.snapshot().first { $0.owner == "FolderChanges.coalesce" && $0.reason == "deadline" }?.count ?? 0) == 1)
    }

    @Test func energySaverStretchesTheCoalescingWaitFourTimes() {
        let energy = EnergyPolicySource()
        let watch = FolderChanges(folders: [], coalesce: .seconds(1), energy: energy, ledger: WakeupLedger())
        #expect(watch.currentCoalesce == .seconds(1))
        energy.update(EnergyPolicy(saverReason: .thermal))
        #expect(watch.currentCoalesce == .seconds(4))
        #expect(FolderChanges(folders: [], ledger: WakeupLedger()).currentCoalesce == .zero)
    }
}
