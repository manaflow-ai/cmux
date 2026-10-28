import CmuxNextCompat
@testable import CmuxNextWakeups
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
        // events() returns once the watch is registered, so the first write needs no head start.
        var changes = await FolderChanges(folders: [missing], ledger: ledger).events().makeAsyncIterator()

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

    /// events() returns only after the kernel has registered the watches (review of #26320:
    /// resume() only schedules the registration, and dispatch_source(3) drops events before it
    /// completes). The watches' queue is held suspended, so no registration handler can run:
    /// events() must not return until the queue is let go, and a write the moment it returns is seen.
    @Test func eventsReturnsOnlyOnceTheWatchesAreRegistered() async throws {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("folder-changes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = DispatchQueue(label: "folder-changes-registration")
        let steps = Steps()
        queue.suspend()
        let pending = Task {
            let stream = await FolderChanges(folders: [folder], ledger: WakeupLedger(), queue: queue).events()
            steps.append("returned")
            // Written before the watch loop can have run.
            try Data([0]).write(to: folder.appendingPathComponent("first.png"))
            return stream
        }
        // Room for a regression to show (events() returning while registration is held); the fixed
        // code cannot return before the queue is let go, however short or long this is.
        try? await Task.sleep(for: .milliseconds(200))
        steps.append("released")
        queue.resume()
        var changes = try await pending.value.makeAsyncIterator()
        #expect(steps.all == ["released", "returned"])
        #expect(await changes.next() != nil)
    }
}

/// What happened, in order, across tasks.
private final class Steps: Sendable {
    private let steps = Mutex<[String]>([])

    func append(_ step: String) { steps.withLock { $0.append(step) } }
    var all: [String] { steps.withLock { $0 } }
}
