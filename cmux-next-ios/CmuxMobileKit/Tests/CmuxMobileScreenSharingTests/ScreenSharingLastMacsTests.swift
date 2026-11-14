#if os(iOS)
import CmuxDeviceHub
import Foundation
import Testing
@testable import CmuxMobileScreenSharing

/// conn-quiet (Leo, 2026-11-14: connectivity should "shut the f*** up and load faster"): the
/// Screen Sharing page draws the Macs the last read list held in its first frame, instead of
/// "Finding your Macs…" until the hub registers this phone, connects and reads the list again.
@MainActor
@Suite struct ScreenSharingLastMacsTests {
    let lastMacsKey = "cmux.screenSharing.lastMacs"

    func studio(online: Bool = true) -> HubDevice {
        HubDevice(id: "studio", name: "Studio", platform: .macos, signingKey: "", macScreenShared: true, online: online)
    }

    func store(holding macs: [HubDevice]) throws -> UserDefaults {
        let store = try #require(UserDefaults(suiteName: "screen-sharing-last-macs-\(UUID().uuidString)"))
        store.set(try JSONEncoder().encode(macs), forKey: lastMacsKey)
        return store
    }

    /// A hub that registered nothing and read no list yet: discovery is `finding`.
    func service(_ store: UserDefaults) -> ScreenSharingService {
        let identity = DeviceIdentity(deviceID: UUID(), keys: TestKeys())
        let client = DeviceHubClient(baseURL: URL(string: "https://hub.invalid")!, identity: identity,
                                     tokens: DeviceHubAccountToken { "token" })
        let hub = DeviceHub(client: client, secrets: MemoryRelaySecretStore(), deviceName: "iPhone", platform: .ios)
        let configuration = ScreenSharingService.Configuration(baseURL: URL(string: "https://hub.invalid")!, bundleIdentifier: "test",
                                                               deviceName: "iPhone", tokens: DeviceHubAccountToken { "token" })
        return ScreenSharingService(hub: hub, configuration: configuration, preferences: ScreenSharingPreferences(store: store))
    }

    @Test func beforeTheListIsReadThePageDrawsTheLastListsMacs() throws {
        let phone = HubDevice(id: "phone", name: "Phone", platform: .ios, online: true)
        let service = service(try store(holding: [studio(online: false), phone,
                                                  HubDevice(id: "mini", name: "Mini", platform: .macos, macScreenShared: true, online: true)]))
        #expect(service.discovery == .finding)
        #expect(service.macs.map(\.id) == ["mini", "studio"], "the last list's Macs, in list order, no phones")
    }

    /// The drawn state may be old: a tap waits for this list instead of acting on it.
    @Test func aTapOnALastListMacWaitsForTheList() throws {
        let service = service(try store(holding: [studio(online: false)]))
        service.select(studio(online: false), scope: .full)
        #expect(service.alert == nil, "no 'offline' alert from the old list")
        #expect(service.viewer == nil)
        #expect(service.pendingSelection?.hostID == "studio")
        service.leaveUnshownRequest()
        #expect(service.pendingSelection == nil, "the page went away")
    }

    @Test func theLastListIsKeptAndSigningOutForgetsIt() throws {
        let store = try store(holding: [])
        let preferences = ScreenSharingPreferences(store: store)
        preferences.rememberMacs([studio()])
        #expect(ScreenSharingPreferences(store: store).lastMacs == [studio()])
        let service = service(store)
        #expect(service.macs == [studio()])
        service.stop()
        #expect(ScreenSharingPreferences(store: store).lastMacs.isEmpty)
        #expect(service.preferences.lastMacs.isEmpty)
    }
}
#endif
