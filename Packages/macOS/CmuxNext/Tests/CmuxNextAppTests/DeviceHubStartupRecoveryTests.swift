import AppKit
import CmuxNextActions
import CmuxNextCompat
import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextSettings
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import CryptoKit
import Observation
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
        let home = MacScreenHomeView(host: pages.host, actions: .init(), devices: .init(pages: pages))
        let shown = MacScreenHomeSnapshot(home: home)
        #expect(shown.devices == .note(try #require(service.settingsModel.state.error)))
        try await clock.waitForSleeper()
        let delay = try #require(clock.sleeperDeadlines.first).offset - clock.now.offset
        // The Rust pacer owns jitter bounds. Here prove the Swift adapter waits
        // for its injected clock, then retries without a new account event.
        #expect(count == 1)
        #expect(clock.sleeperCount == 1)
        clock.advance(by: delay)
        #expect(await events.next() == 2)
        try await clock.waitForSleeper()
        #expect(clock.sleeperCount == 1)
        service.willSignOut()
        #expect(service.settingsModel.state.error == nil)
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(60))
        #expect(count == 2)
    }

    /// Successful construction clears the startup error and cancels its retry timer.
    @Test func successfulRetryClearsTheStartupFailure() async throws {
        let pages = pages(), clock = ManualClock(), hub = makeHub()
        let (installed, report) = AsyncStream<Bool>.makeStream()
        var count = 0
        let service = DeviceHubService(pages: pages, account: .init(awaitRestored: {}, userID: { "account" },
            accessToken: { throw CancellationError() }), bundleIdentifier: "test.hub-recovery", loginKeychain: LoginKeychain(),
            selectedBaseURL: URL(string: "https://hub.invalid"), retryClock: clock,
            makeAppHub: { _, _, _, _, _ in
                count += 1
                if count == 1 { throw DeviceIdentity.Failure.secureEnclaveUnavailable }
                return hub
            })
        service.hubChanged = { made, _, _ in report.yield(made === hub) }
        defer { service.willSignOut(); report.finish() }
        service.start(settings: settings())
        try await clock.waitForSleeper()
        #expect(pages.hubStartupError == "device_identity_secure_enclave_unavailable")
        clock.advance(by: .seconds(2))
        var events = installed.makeAsyncIterator()
        #expect(await events.next() == true)
        #expect(pages.hub === hub)
        #expect(pages.hubStartupError == nil)
        #expect(clock.sleeperCount == 0)
        #expect(count == 2)
    }

    @Observable @MainActor final class AccountState {
        var user = "old"
    }

    /// A Keychain read may ignore cancellation: its late result cannot replace a newer account's hub.
    @Test func anOldIdentityLoadCannotReplaceTheNewAccount() async throws {
        let pages = pages(), clock = ManualClock(), account = AccountState()
        let oldHub = makeHub(), newHub = makeHub()
        let (started, reportStart) = AsyncStream<Int>.makeStream()
        let (installed, reportInstall) = AsyncStream<Bool>.makeStream()
        var oldLoad: CheckedContinuation<DeviceHub, Never>?
        var count = 0
        let service = DeviceHubService(pages: pages, account: .init(awaitRestored: {}, userID: { account.user },
            accessToken: { throw CancellationError() }), bundleIdentifier: "test.hub-recovery", loginKeychain: LoginKeychain(),
            selectedBaseURL: URL(string: "https://hub.invalid"), retryClock: clock,
            makeAppHub: { _, _, _, _, _ in
                count += 1
                if count == 1 {
                    let result = await withCheckedContinuation { oldLoad = $0; reportStart.yield(1) }
                    reportStart.yield(3)
                    return result
                }
                return newHub
            })
        service.hubChanged = { made, _, _ in reportInstall.yield(made === newHub) }
        defer { service.willSignOut(); reportStart.finish(); reportInstall.finish() }
        service.start(settings: settings())
        var starts = started.makeAsyncIterator(), installs = installed.makeAsyncIterator()
        #expect(await starts.next() == 1)
        account.user = "new"
        #expect(await installs.next() == true)
        try #require(oldLoad).resume(returning: oldHub)
        #expect(await starts.next() == 3)
        #expect(pages.hub === newHub)
        #expect(pages.hubStartupError == nil)
        #expect(clock.sleeperCount == 0)
    }

    private func makeHub() -> DeviceHub {
        let identity = DeviceIdentity(deviceID: UUID(), keys: Keys())
        let client = DeviceHubClient(baseURL: URL(string: "https://hub.invalid")!, identity: identity,
                                    tokens: DeviceHubAccountToken { throw CancellationError() })
        return DeviceHub(client: client, secrets: MemoryRelaySecretStore(), deviceName: "Test Mac")
    }

    nonisolated private struct Keys: DeviceKeyMaterial {
        let signing = P256.Signing.PrivateKey()
        let agreement = P256.KeyAgreement.PrivateKey()
        var signingPublicKey: P256.Signing.PublicKey { signing.publicKey }
        var agreementPublicKey: P256.KeyAgreement.PublicKey { agreement.publicKey }
        func signature(for message: Data) throws -> P256.Signing.ECDSASignature { try signing.signature(for: message) }
        func open(_ ciphertext: Data, encapsulatedKey: Data, info: Data) throws -> Data {
            var recipient = try HPKE.Recipient(privateKey: agreement, ciphersuite: RelaySealing.ciphersuite, info: info,
                                               encapsulatedKey: encapsulatedKey)
            return try recipient.open(ciphertext)
        }
    }

}
