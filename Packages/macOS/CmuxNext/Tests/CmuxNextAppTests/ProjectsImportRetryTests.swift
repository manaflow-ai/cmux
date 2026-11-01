@testable import CmuxNextAgentLanes
import CmuxNextCompat
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// A failed project import must not run again on every chat index change (v2.2.10-opt P0: 5,311
/// "project import failed" in 17 h on a Mac at 19.9 of 21.5 GB swap). Each failed `project.sync`
/// left the next relay fresh, so every index change sent the sync again and the daemon read every
/// editor source again. After a failure the import waits a backoff: changes in the wait add no
/// attempt, the retry comes once at its end, and a new daemon connection retries at once.
/// The attempts are counted; a manual clock moves the backoff, so no wall time decides a result.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct ProjectsImportRetryTests {
    /// After N failures, N index changes add no attempt; the retry after the wait is one attempt.
    @Test func aFailingImportWaitsItsBackoffInsteadOfRetryingOnEveryIndexChange() async throws {
        let rig = ImportRig()
        rig.importer.start(feed: nil)
        await rig.settle()
        #expect(rig.attempts.count == 1, "the first relay did not send")
        #expect(rig.attempts.fresh == [true], "a new connection's first relay did not sync")

        for _ in 0..<20 {
            rig.importer.indexChanged()
            await rig.settle()
        }
        #expect(rig.attempts.count == 1,
                "20 index changes after a failure sent \(rig.attempts.count - 1) more imports (want 0: the retry waits its backoff)")

        // The retry comes at the end of the wait, with no index change.
        try await rig.clock.waitForSleeper()
        try await rig.runRetry()
        #expect(rig.attempts.count == 2, "the retry after the backoff ran \(rig.attempts.count - 1) times (want 1)")
        #expect(rig.attempts.fresh == [true, true], "the retry of a failed sync did not sync again")

        for _ in 0..<20 {
            rig.importer.indexChanged()
            await rig.settle()
        }
        #expect(rig.attempts.count == 2, "index changes after the second failure sent \(rig.attempts.count - 2) more imports")
        try await rig.clock.waitForSleeper()
        #expect(rig.clock.sleeperCount == 1, "one failed import holds \(rig.clock.sleeperCount) retry waits (want 1)")
    }

    /// A new daemon connection can make the import succeed: it retries at once, not after the wait.
    @Test func aNewDaemonConnectionRetriesAtOnce() async throws {
        let rig = ImportRig()
        rig.importer.start(feed: nil)
        await rig.settle()
        #expect(rig.attempts.count == 1)

        rig.connect(NSObject(), failing: false)
        rig.importer.indexChanged()
        await rig.settle()
        #expect(rig.attempts.count == 2, "a new connection waited the old connection's backoff")
        #expect(rig.attempts.fresh == [true, true], "the new connection's relay did not sync first")
        #expect(rig.clock.sleeperCount == 0, "a retry wait outlived the success")
    }

    /// A retry that succeeds ends the waits: later index changes send only what changed.
    @Test func aRetryThatSucceedsEndsTheBackoff() async throws {
        let rig = ImportRig()
        rig.importer.start(feed: nil)
        await rig.settle()
        rig.failing = false
        try await rig.clock.waitForSleeper()
        try await rig.runRetry()
        #expect(rig.attempts.count == 2, "the retry did not run")
        #expect(rig.clock.sleeperCount == 0, "a retry wait outlived the success")

        // Synced, and no chat feed: nothing changed, so an index change sends nothing.
        rig.importer.indexChanged()
        await rig.settle()
        #expect(rig.attempts.count == 2, "an index change after the success sent again with nothing to send")
    }
}

/// The importer on a fake daemon target whose sends fail or succeed, a manual clock and a count of
/// every send.
@MainActor
private final class ImportRig {
    let clock = ManualClock()
    let attempts = ImportAttempts()
    private(set) var importer: ProjectsImport!
    private var connection: NSObject = NSObject()
    var failing: Bool {
        get { attempts.failing }
        set { attempts.failing = newValue }
    }

    init() {
        attempts.failing = true
        importer = ProjectsImport(target: { [unowned self] in
            let attempts = self.attempts
            return ProjectsImport.Target(id: ObjectIdentifier(self.connection)) { _, fresh in
                attempts.record(fresh: fresh)
            }
        }, socketPath: { nil }, connection: { nil }, clock: clock)
    }

    /// A new daemon connection, whose sends fail or not.
    func connect(_ connection: NSObject, failing: Bool) {
        self.connection = connection
        self.failing = failing
    }

    /// Waits for every relay in flight, and any relay its end starts.
    func settle() async {
        while let relay = importer.inFlight { await relay.value }
    }

    /// Ends the pending retry wait (past the longest backoff) and waits for the retry's relay.
    func runRetry() async throws {
        let retry = try #require(importer.pendingRetry, "no retry was pending after a failure")
        clock.advance(by: .seconds(3_600))
        await retry.value
        await settle()
    }
}

/// Every send the importer made, from the thread it ran on.
private nonisolated final class ImportAttempts: Sendable {
    private let state = Mutex<(fresh: [Bool], failing: Bool)>(([], true))

    var count: Int { state.withLock { $0.fresh.count } }
    var fresh: [Bool] { state.withLock { $0.fresh } }
    var failing: Bool {
        get { state.withLock { $0.failing } }
        set { state.withLock { $0.failing = newValue } }
    }

    func record(fresh: Bool) -> ProjectsImport.Sent {
        let failing = state.withLock { state in
            state.fresh.append(fresh)
            return state.failing
        }
        // A relay on a synced connection stays synced; a fresh one is synced only by a sync that went.
        return ProjectsImport.Sent(synced: !fresh || !failing, delivered: [:], failed: failing)
    }
}
