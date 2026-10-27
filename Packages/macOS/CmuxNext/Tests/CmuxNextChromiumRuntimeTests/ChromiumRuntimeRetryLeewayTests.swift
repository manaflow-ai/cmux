import Foundation
import Testing
@testable import CmuxNextChromiumRuntime
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

/// The wait after a failed install attempt is a ``Backoff`` on the retry table: jittered, so
/// clients that failed on the same outage do not retry in step (Chromium's `net::BackoffEntry`,
/// net/base/backoff_entry.cc), asking the OS for ``Backoff/tolerance(for:)`` so the kernel can
/// coalesce the wake (p14-energy Q1), and recorded in the ledger as `backoff`.
struct ChromiumRuntimeRetryLeewayTests {
    private static func installer(retryDelays: [Duration], random: @escaping @Sendable () -> Double,
                                  clock: ManualClock, ledger: WakeupLedger, in folder: TemporaryFolder) throws -> ChromiumRuntimeInstaller {
        let store = ChromiumRuntimeStore(root: folder.url.appending(path: "ChromiumRuntime"))
        let (data, pin) = try PackFixture.make(in: folder.url)
        return ChromiumRuntimeInstaller(
            pin: pin, store: store, downloader: MemoryDownloader(bytes: data, failFirst: 1),
            unpacker: TarChromiumRuntimeUnpacker(), signatures: RecordingSignatures(), network: FixedNetwork(),
            retryDelays: retryDelays, retryRandom: random, maxAttempts: 3, clock: clock, ledger: ledger)
    }

    @Test func theRetryWaitIsABackoffStepWithItsToleranceAndLedgerRecord() async throws {
        let folder = try TemporaryFolder()
        let clock = ManualClock(), ledger = WakeupLedger()
        let step = Duration.seconds(5)
        let installer = try Self.installer(retryDelays: [step], random: { 0.5 }, clock: clock, ledger: ledger, in: folder)
        let run = Task { await installer.run(.user) }

        try await clock.waitForSleeper()
        let request = try #require(clock.sleepRequests.last)
        #expect(request.deadline == clock.now.advanced(by: step))
        #expect(request.tolerance == Backoff.tolerance(for: step))
        #expect(request.tolerance == .milliseconds(500))

        clock.advance(by: step)
        #expect(await run.value.name == "installed")
        let entries = ledger.snapshot()
        #expect(entries.map(\.owner) == [ChromiumRuntimeInstaller.retryOwner])
        #expect(entries.map(\.reason) == ["backoff"])
        withExtendedLifetime(folder) {}
    }

    /// The step is jittered: the lowest draw waits 20% short of the table's 5 s.
    @Test func theRetryWaitIsJittered() async throws {
        let folder = try TemporaryFolder()
        let clock = ManualClock()
        let installer = try Self.installer(retryDelays: [.seconds(5)], random: { 0 }, clock: clock, ledger: WakeupLedger(), in: folder)
        let run = Task { await installer.run(.user) }

        try await clock.waitForSleeper()
        let request = try #require(clock.sleepRequests.last)
        #expect(request.deadline == clock.now.advanced(by: .seconds(4)))
        #expect(request.tolerance == Backoff.tolerance(for: .seconds(4)))

        clock.advance(by: .seconds(4))
        #expect(await run.value.name == "installed")
        withExtendedLifetime(folder) {}
    }
}
