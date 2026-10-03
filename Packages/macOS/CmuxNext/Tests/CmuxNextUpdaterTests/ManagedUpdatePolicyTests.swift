import CmuxUpdater
import Foundation
import Testing
@testable import CmuxNextUpdater

/// `UpdateChannel` and `MinimumVersion` (enterprise P17-2).
@MainActor
@Suite struct ManagedUpdatePolicyTests {
    private func service(short: String = "0.64.25", bundle: String = "com.cmuxterm.app") -> UpdaterService {
        UpdaterService(identity: AppcastFixtures.identity(bundle: bundle, short: short), policy: ManagedUpdatePolicy { false },
                       defaults: UserDefaults(suiteName: "cmux-next-managed-\(UUID().uuidString)")!, enableSparkle: false)
    }

    @Test func versionsCompareByMajorMinorPatch() {
        #expect(UpdaterService.isOlder("0.64.25", than: "0.65.0"))
        #expect(UpdaterService.isOlder("1.9.9", than: "1.10.0"))
        #expect(!UpdaterService.isOlder("1.10.0", than: "1.9.9"))
        #expect(!UpdaterService.isOlder("2.0.0", than: "2.0.0"))
        #expect(UpdaterService.isOlder("2.0.0-rc1", than: "2.0.1"))
        #expect(!UpdaterService.isOlder("garbage", than: "1.0.0"))
        // An admin's two-part or one-part minimum pads with zeros.
        #expect(UpdaterService.isOlder("0.64.25", than: "0.65"))
        #expect(UpdaterService.isOlder("0.64.25", than: "1"))
        #expect(!UpdaterService.isOlder("1.0.0", than: " 1 "))
    }

    @Test func aMinimumAboveTheRunningVersionRequiresAnUpdate() {
        let service = service(short: "0.64.25")
        #expect(service.requiredMinimumVersion == nil)
        service.applyManagedPolicy(channel: nil, minimumVersion: "0.65.0")
        #expect(service.requiredMinimumVersion == "0.65.0")
        service.applyManagedPolicy(channel: nil, minimumVersion: "0.64.0")
        #expect(service.requiredMinimumVersion == nil)
    }

    /// The sheet says what the organization requires and offers no "Later".
    @Test func theRequiredSheetHasNoLater() {
        let sheet = UpdateSheetContent(symbol: "arrow.down", title: "cmux 0.65.0 Is Available", detail: "notes", buttons: [.later, .install])
        let required = sheet.requiring("0.65.0")
        #expect(required.buttons == [.install])
        #expect(required.detail?.contains("0.65.0") == true)
        #expect(required.detail?.contains("notes") == true)
    }

    @Test func aPinnedChannelRefusesTheOtherOne() throws {
        let service = service(bundle: "com.cmuxterm.app")
        let target = try #require(service.identity.channelSwitchTarget)
        #expect(service.channelSwitchUnavailableReason == nil)
        let other = target == .nightly ? "Stable" : "NIGHTLY"
        service.applyManagedPolicy(channel: other, minimumVersion: nil)
        #expect(service.channelSwitchUnavailableReason != nil)
        #expect(throws: UpdaterUnavailable.self) { try service.switchChannel(to: target) }
        service.applyManagedPolicy(channel: target.rawValue, minimumVersion: nil)
        #expect(service.channelSwitchUnavailableReason == nil)
        // An unknown channel name pins nothing.
        service.applyManagedPolicy(channel: "beta", minimumVersion: nil)
        #expect(service.managedChannel == nil && service.channelSwitchUnavailableReason == nil)
    }
}
