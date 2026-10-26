import Foundation
import Testing
@testable import CmuxNextChromiumRuntime
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

/// The wait after a failed install attempt is a backoff: its sleep asks the OS for
/// ``Backoff/tolerance(for:)`` (10% of the step), so the kernel can coalesce the wake
/// (p14-energy Q1; Apple's Energy Efficiency Guide, "Minimize Timer Usage").
struct ChromiumRuntimeRetryLeewayTests {
    @Test func theRetryWaitAsksForTheBackoffTolerance() async throws {
        let folder = try TemporaryFolder()
        let store = ChromiumRuntimeStore(root: folder.url.appending(path: "ChromiumRuntime"))
        let (data, pin) = try PackFixture.make(in: folder.url)
        let clock = ManualClock()
        let step = Duration.seconds(5)
        let installer = ChromiumRuntimeInstaller(
            pin: pin, store: store, downloader: MemoryDownloader(bytes: data, failFirst: 1),
            unpacker: TarChromiumRuntimeUnpacker(), signatures: RecordingSignatures(), network: FixedNetwork(),
            retryDelays: [step], maxAttempts: 3, clock: clock)
        let run = Task { await installer.run(.user) }

        try await clock.waitForSleeper()
        let request = try #require(clock.sleepRequests.last)
        #expect(request.deadline == clock.now.advanced(by: step))
        #expect(request.tolerance == Backoff.tolerance(for: step))
        #expect(request.tolerance == .milliseconds(500))

        clock.advance(by: step)
        #expect(await run.value.name == "installed")
        withExtendedLifetime(folder) {}
    }
}
