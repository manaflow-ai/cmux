import CmuxNextCompat
import CmuxNextControl
import Foundation
import Testing
@testable import CmuxNextApp

/// Restart to Update waits for the old process to exit, and the quit's last step, CefShutdown on the main
/// thread, never returned before the 4 s keep-quit deadline ended the process: 11 of Leo's 20 NIGHTLY hang
/// files (cmuxterm-hq#8608) and 10 of 10 fleet quits (hq#11994, Chromium's thread pool waiting on a Keychain
/// prompt nobody answers). Right before CefShutdown the quit now hides its windows, drains the closing pages'
/// drafts, and gives CefShutdown `engineShutdownLimit`, so a stuck one ends the process then.
///
/// No clock decides this test: the deadline's limits are recorded and passed by hand (``DeadlineWaits``),
/// and the draft waits behind a held save only the drain lets go (``DrainGate``).
@MainActor
@Suite(.serialized)
struct QuitEngineStopTests {
    @Test func aStuckCefShutdownEndsTheQuitAtItsOwnLimitNotTheKeepDeadline() async throws {
        let directory = try QuitStateFilesTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DrainGate()
        defer { gate.releaseHeldSave() }
        let services = QuitStateFilesTests.services(gate)
        let written = QuitStateFilesTests.queueDraft(in: directory, gate: gate)
        let waits = DeadlineWaits()
        services.quit.deadline = waits.deadline()
        // A keep quit armed its deadline when it was decided (`QuitCoordinator.complete`).
        services.quit.deadline.arm(after: QuitDeadline.keepQuitLimit)

        await services.quit.engineWillStop(hide: { gate.log("hide") })

        #expect(gate.events() == ["hide", "drain began"], "the engine stop's order was \(gate.events())")
        #expect(written(), "CefShutdown would begin before the draft a closing page queued was on disk")
        #expect(waits.limits() == [QuitDeadline.keepQuitLimit, QuitDeadline.engineShutdownLimit],
                "CefShutdown got no limit of its own: a stuck one holds the exit until the keep deadline")
        #expect(QuitDeadline.engineShutdownLimit < QuitDeadline.keepQuitLimit)
        // CefShutdown never returns: its limit passes first and ends the quit, once.
        waits.pass(QuitDeadline.engineShutdownLimit)
        #expect(waits.ends() == 1)
        waits.pass(QuitDeadline.keepQuitLimit)
        #expect(waits.ends() == 1, "the keep deadline ended the quit a second time")
    }
}

/// A ``QuitDeadline``'s limits, recorded instead of waited out; ``pass(_:)`` ends one's wait. Its ends counted.
private nonisolated final class DeadlineWaits: Sendable {
    private let state = Mutex<(waits: [(Duration, @Sendable () -> Void)], ends: Int)>(([], 0))

    func deadline() -> QuitDeadline {
        QuitDeadline(reason: "a quit test", end: { self.state.withLock { $0.ends += 1 } },
                     schedule: { limit, fire in self.state.withLock { $0.waits.append((limit, fire)) } })
    }

    func limits() -> [Duration] { state.withLock { $0.waits.map(\.0) } }

    func ends() -> Int { state.withLock { $0.ends } }

    /// Every wait of `limit` passes now.
    func pass(_ limit: Duration) {
        let fires = state.withLock { $0.waits.filter { $0.0 == limit }.map(\.1) }
        for fire in fires { fire() }
    }
}
