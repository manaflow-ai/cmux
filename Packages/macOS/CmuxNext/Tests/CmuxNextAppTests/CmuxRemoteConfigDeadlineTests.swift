import CmuxNextActions
import CmuxNextCompat
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CmuxRemoteConfigDeadlineTests {
    /// Before the fix this suspends forever: cancelling the caller cannot remove its continuation.
    @Test func cancelledConfigurationWaitReturnsWithoutSettings() async {
        let service = CmuxRemoteService(connection: { nil })
        let (started, report) = AsyncStream<Bool>.makeStream()
        let waiting = Task { @MainActor in
            report.yield(true)
            return await service.waitAvailable()
        }
        var events = started.makeAsyncIterator()
        #expect(await events.next() == true)
        waiting.cancel()
        #expect(await waiting.value == false)
        report.finish()
    }

    @Test func absentConfigurationEndsWithNamedErrorAndLateConfigCanRecover() async throws {
        let clock = ManualClock()
        let service = CmuxRemoteService(clock: clock, connection: { nil })
        let waiting = Task { try await service.configuredAvailability() }
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        do {
            _ = try await waiting.value
            Issue.record("A missing configuration must fail at its deadline")
        } catch {
            #expect((error as? CmuxRemoteError)?.description == "device_hub_configuration_timeout")
        }
        #expect(clock.sleeperCount == 0)
        service.currentConfig = { (false, false, false) }
        #expect(try await service.configuredAvailability() == false)
        #expect(clock.sleeperCount == 0)
    }

    @Test func loadedConfigurationResumesEveryCallerAndCancelsDeadlines() async throws {
        let clock = ManualClock()
        let service = CmuxRemoteService(clock: clock, connection: { nil })
        let first = Task { try await service.configuredAvailability() }
        let second = Task { try await service.configuredAvailability() }
        try await clock.waitForSleeper()
        service.currentConfig = { (false, false, false) }
        #expect(try await first.value == false)
        #expect(try await second.value == false)
        #expect(clock.sleeperCount == 0)
    }

    @Test func cancellationBeforeRegistrationLeavesNoDeadline() async {
        let clock = ManualClock()
        let service = CmuxRemoteService(clock: clock, connection: { nil })
        let waiting = Task { await service.waitAvailable() }
        waiting.cancel()
        #expect(await waiting.value == false)
        #expect(clock.sleeperCount == 0)
    }

    @Test func hubShowsConfigurationTimeoutWithoutFallingBackToAnotherIdentity() async throws {
        let clock = ManualClock(), retryClock = ManualClock()
        let remote = CmuxRemoteService(clock: clock, connection: { nil })
        let file = FileManager.default.temporaryDirectory.appending(path: "config-deadline-\(UUID().uuidString)/screen.json")
        let pages = MacScreenPages(store: MacScreenStore(file: file, removeLinkPairings: {}), work: BackgroundWork())
        let settings = SettingsController(registry: ActionRegistry(), fileURL: file.deletingLastPathComponent().appending(path: "config.json"))
        var appIdentityAttempts = 0
        let hub = DeviceHubService(pages: pages, account: .init(awaitRestored: {}, userID: { "account" },
            accessToken: { throw CancellationError() }), bundleIdentifier: "test.config-deadline", loginKeychain: LoginKeychain(),
            selectedBaseURL: URL(string: "https://hub.invalid"), retryClock: retryClock,
            makeAppHub: { _, _, _, _, _ in appIdentityAttempts += 1; throw CancellationError() })
        hub.makeRemoteHub = { _, _ -> DeviceHub? in
            _ = try await remote.configuredAvailability()
            return nil
        }
        defer { hub.willSignOut() }
        hub.start(settings: settings)
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(30))
        try await retryClock.waitForSleeper()
        #expect(pages.hubStartupError == "device_hub_configuration_timeout")
        #expect(hub.settingsModel.state.error != nil)
        #expect(appIdentityAttempts == 0)
        hub.willSignOut()
        #expect(retryClock.sleeperCount == 0)
        #expect(pages.hubStartupError == nil)
    }
}
