import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// Identity failures happen before a DeviceHub exists: account sign-in alone cannot report them.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct DeviceHubStartupRecoveryTests {
    private func pages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "hub-recovery-\(UUID().uuidString)/screen.json")
        return MacScreenPages(store: MacScreenStore(file: file, removeLinkPairings: {}), work: BackgroundWork())
    }

    private func settings() -> SettingsController {
        SettingsController(registry: ActionRegistry(), fileURL: FileManager.default.temporaryDirectory
            .appending(path: "hub-recovery-\(UUID().uuidString)/config.json"))
    }

    @Test func identityFailureIsVisibleAndRetriesWithoutAnAccountChange() async throws {
        let pages = pages(), clock = ManualClock()
        let (attempts, report) = AsyncStream<Int>.makeStream()
        var count = 0
        let service = DeviceHubService(pages: pages, account: .init(awaitRestored: {}, userID: { "account" },
            accessToken: { throw CancellationError() }), bundleIdentifier: "test.hub-recovery", loginKeychain: LoginKeychain(),
            selectedBaseURL: URL(string: "https://hub.invalid"), retryClock: clock,
            makeAppHub: { _, _, _, _, _ in
                count += 1
                report.yield(count)
                throw DeviceIdentity.Failure.keychain(-25308)
            })
        defer { service.willSignOut(); report.finish() }
        var events = attempts.makeAsyncIterator()
        service.start(settings: settings())
        #expect(await events.next() == 1)
        let state = await pages.deviceHubDebug([:], settings: service.settingsModel, openTab: { _, _ in nil })
        #expect(state.objectValue?["last_error"]?.stringValue == "device_identity_keychain_-25308")
        #expect(service.settingsModel.state.error != nil)
        #expect(service.settingsModel.state.status.tone == "danger")
        try await clock.waitForSleeper()
        let delay = try #require(clock.sleeperDeadlines.first).offset - clock.now.offset
        #expect(delay >= .milliseconds(800) && delay <= .milliseconds(1200))
        clock.advance(by: delay)
        #expect(await events.next() == 2)
        try await clock.waitForSleeper()
        let second = try #require(clock.sleeperDeadlines.first).offset - clock.now.offset
        #expect(second >= .milliseconds(1600) && second <= .milliseconds(2400))
        service.willSignOut()
        #expect(service.settingsModel.state.error == nil)
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(60))
        #expect(count == 2)
    }
}
