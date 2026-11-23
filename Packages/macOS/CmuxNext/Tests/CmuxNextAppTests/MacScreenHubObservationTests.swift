import CmuxNextDevices
@testable import CmuxNextMacScreen
import CmuxNextSettings
import CmuxNextWakeups
import CryptoKit
import Foundation
import Observation
import Testing

/// Software keys: tests only (the app's keys are in the Secure Enclave).
nonisolated private struct ObservedHubTestKeys: DeviceKeyMaterial {
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

@MainActor
private func testHub() -> DeviceHub {
    let identity = DeviceIdentity(deviceID: UUID(), keys: ObservedHubTestKeys())
    let client = DeviceHubClient(baseURL: URL(string: "https://hub.invalid")!, identity: identity,
                                 tokens: DeviceHubAccountToken { throw DeviceHubError.notSignedIn })
    return DeviceHub(client: client, secrets: MemoryRelaySecretStore(), deviceName: "Test Mac")
}

/// CMUX-572: a signed-in Mac read "Sign in to cmux to share this Mac." in `action describe` and the
/// palette because `MacScreenPages.hub` was a plain property: the action's reason, read inside an
/// observation at launch (before the hub's identity loaded), never fired again. And a Release build
/// had no readout of the hub, so nobody could tell a stale reason from a hub that never started.
@MainActor
struct MacScreenHubObservationTests {
    private func makePages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        return MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
    }

    /// Final class: the onChange closure may run off the main actor.
    nonisolated private final class Fired: @unchecked Sendable { var count = 0 }

    /// A reason that reads the hub is read again when the hub comes up, and again when it goes.
    @Test func aReasonReadingTheHubSeesItArriveAndLeave() {
        let pages = makePages()
        let reason: @MainActor () -> String? = { pages.hub == nil ? "Sign in to cmux to share this Mac." : nil }
        let fired = Fired()
        let before = withObservationTracking { reason() } onChange: { fired.count += 1 }
        #expect(before != nil)
        pages.hub = testHub()
        #expect(fired.count == 1, "the hub arriving fires the reason's observation")
        let after = withObservationTracking { reason() } onChange: { fired.count += 1 }
        #expect(after == nil)
        pages.hub = nil
        #expect(fired.count == 2, "signing out fires it too")
        #expect(reason() != nil)
    }

    /// The same hub set again changes nothing (no sign-out of its sessions, no firing).
    @Test func settingTheSameHubIsNoChange() {
        let pages = makePages()
        let hub = testHub()
        pages.hub = hub
        let fired = Fired()
        _ = withObservationTracking { pages.hub } onChange: { fired.count += 1 }
        pages.hub = hub
        #expect(fired.count == 0)
        #expect(pages.hub === hub && pages.hubBox.hub === hub)
    }

    /// `mac_screen.state` (every build) says whether the hub runs and, with it, this device's state.
    @Test func theStateReadsTheHub() throws {
        let pages = makePages()
        pages.hubConfigured = true
        pages.hubStartupError = "device_identity_keychain_-25308"
        let off = try #require(pages.stateAnswer([:]).objectValue?["hub"]?.objectValue)
        #expect(off["configured"]?.boolValue == true && off["running"]?.boolValue == false)
        #expect(off["startup_error"]?.stringValue == "device_identity_keychain_-25308")
        #expect(off["devices"] == nil)

        let hub = testHub()
        pages.hubStartupError = nil
        pages.hub = hub
        let on = try #require(pages.stateAnswer([:]).objectValue?["hub"]?.objectValue)
        #expect(on["running"]?.boolValue == true && on["startup_error"]?.isNull == true)
        #expect(on["status"]?.stringValue == "idle" && on["connection"]?.stringValue == "disconnected")
        #expect(on["this_device"]?.stringValue == hub.identity.id)
        #expect(on["registered"]?.boolValue == false && on["sharing"]?.boolValue == false)
        #expect(on["served_by_cmux_remote"]?.boolValue == false)
        #expect(on["devices"]?.arrayValue?.isEmpty == true)
        pages.hub = nil
    }
}
