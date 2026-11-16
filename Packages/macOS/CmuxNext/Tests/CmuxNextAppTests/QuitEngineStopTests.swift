import CmuxNextCompat
import CmuxNextControl
import Foundation
import Testing
@testable import CmuxNextApp

/// Restart to Update waits for the old process to exit, and the quit's last step, CefShutdown on the main
/// thread, never returned before the 4 s keep-quit deadline ended the process: 11 of Leo's 20 NIGHTLY hang
/// files (cmuxterm-hq#8608) and 10 of 10 fleet quits (hq#11994, Chromium's thread pool waiting on a Keychain
/// prompt nobody answers). The engine stop now drains the closing pages' drafts, then gives CefShutdown
/// `engineShutdownLimit` before the deadline ends the process.
///
/// Harness: the keep quit's deadline is armed as `QuitCoordinator.complete` arms it, the engine stop runs,
/// then the test blocks the main thread as a CefShutdown that never returns does, and reads when the
/// deadline's end ran.
@MainActor
@Suite(.serialized)
struct QuitEngineStopTests {
    @Test func aCefShutdownThatNeverReturnsEndsTheQuitWithinItsLimitNotTheKeepDeadline() async throws {
        let directory = try QuitStateFilesTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DrainGate()
        defer { gate.releaseHeldSave() }
        let services = QuitStateFilesTests.services(gate)
        let written = QuitStateFilesTests.queueDraft(in: directory, gate: gate)
        let end = EndMark()
        services.quit.deadline = QuitDeadline(reason: "a quit test", end: { end.mark() })
        services.quit.deadline.arm(after: QuitDeadline.keepQuitLimit)

        let began = ContinuousClock.now
        await services.quit.engineWillStop(hide: { gate.log("hide") })
        #expect(gate.events() == ["hide", "drain began"], "the engine stop's order was \(gate.events())")
        #expect(written(), "CefShutdown began before the draft a closing page queued was on disk")
        let ended = try #require(Self.blockMainUntil(end, from: began), "the quit never ended")

        print("QuitEngineStop: Restart to Update waits \(ended) from the engine stop to the exit (CefShutdown never returns)")
        #expect(ended < QuitDeadline.engineShutdownLimit + .milliseconds(500), "the quit ended \(ended) after CefShutdown began")
        #expect(end.count() == 1, "the end ran \(end.count()) times")
    }

    /// The same harness without the engine stop's bound (as before): the keep quit's 4 s deadline ends it.
    @Test func withoutTheBoundTheKeepDeadlineEndsAStuckCefShutdown() throws {
        let end = EndMark()
        let deadline = QuitDeadline(reason: "a quit test", end: { end.mark() })
        let began = ContinuousClock.now
        deadline.arm(after: QuitDeadline.keepQuitLimit)
        let ended = try #require(Self.blockMainUntil(end, from: began), "the quit never ended")

        print("QuitEngineStop: without the bound the exit waits \(ended) (the keep-quit deadline)")
        #expect(ended >= QuitDeadline.keepQuitLimit)
    }

    /// Blocks the main thread, as CefShutdown does, until `end` ran or 1 s past the keep-quit deadline;
    /// the time from `start` to the end.
    private static func blockMainUntil(_ end: EndMark, from start: ContinuousClock.Instant) -> Duration? {
        while end.at() == nil, ContinuousClock.now - start < QuitDeadline.keepQuitLimit + .seconds(1) {
            // concurrency-allow: test only; stands in for CefShutdown holding the main thread
            usleep(5_000)
        }
        return end.at().map { $0 - start }
    }
}

/// When a quit deadline's end ran (on the deadline's thread), and how often.
nonisolated final class EndMark: Sendable {
    private let state = Mutex<(at: ContinuousClock.Instant?, count: Int)>((nil, 0))

    func mark() {
        state.withLock { state in
            state.count += 1
            if state.at == nil { state.at = .now }
        }
    }

    func at() -> ContinuousClock.Instant? { state.withLock { $0.at } }

    func count() -> Int { state.withLock { $0.count } }
}
