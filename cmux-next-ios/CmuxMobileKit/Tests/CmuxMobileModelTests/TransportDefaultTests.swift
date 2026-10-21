import Foundation
import Testing
@testable import CmuxMobileModel

/// verify/hybrid-link.md: WireGuard is the default transport (browser video
/// rides a WebRTC media session beside it); a saved choice stays.
@MainActor
@Suite struct TransportDefaultTests {
    private func defaults() -> UserDefaults {
        let name = "transport-default-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func anInstallWithNoSavedChoiceGetsWireGuard() {
        #expect(SettingsStore(defaults: defaults()).transport == .wireguard)
    }

    @Test func aSavedWebRTCChoiceStays() {
        let defaults = defaults()
        defaults.set("webrtc", forKey: "cmuxMobile.settings.transport")
        #expect(SettingsStore(defaults: defaults).transport == .webrtc)
        defaults.set("wireguard", forKey: "cmuxMobile.settings.transport")
        #expect(SettingsStore(defaults: defaults).transport == .wireguard)
    }

    @Test func choosingSavesIt() {
        let defaults = defaults()
        let store = SettingsStore(defaults: defaults)
        store.transport = .webrtc
        #expect(defaults.string(forKey: "cmuxMobile.settings.transport") == "webrtc")
        #expect(SettingsStore(defaults: defaults).transport == .webrtc)
    }

    @Test func thePickerListsWireGuardFirstAsRecommended() {
        #expect(TransportKind.allCases == [.wireguard, .webrtc])
        #expect(TransportKind.wireguard.pickerTitle == "WireGuard (recommended)")
        #expect(TransportKind.webrtc.pickerTitle == "WebRTC only")
        #expect(TransportKind.webrtc.title == "WebRTC only")
    }

    /// transport-verify-20261019.md defect 4: Block UDP is a WireGuard dial
    /// policy (WebRTC ignores it), so the Settings root never says a WebRTC
    /// link has UDP blocked.
    @Test func theSettingsValueNamesOnlyTheDebugPoliciesThatApply() {
        #expect(TransportKind.webrtc.settingsValue(blockUDP: true, relayOnly: false) == "WebRTC only")
        #expect(TransportKind.webrtc.settingsValue(blockUDP: true, relayOnly: true) == "WebRTC only, relay only")
        #expect(TransportKind.webrtc.settingsValue(blockUDP: false, relayOnly: true) == "WebRTC only, relay only")
        #expect(TransportKind.wireguard.settingsValue(blockUDP: true, relayOnly: false) == "WireGuard, UDP blocked")
        #expect(TransportKind.wireguard.settingsValue(blockUDP: true, relayOnly: true) == "WireGuard, UDP blocked")
        #expect(TransportKind.wireguard.settingsValue(blockUDP: false, relayOnly: true) == "WireGuard, relay only")
        #expect(TransportKind.wireguard.settingsValue(blockUDP: false, relayOnly: false) == "WireGuard")
    }
}
