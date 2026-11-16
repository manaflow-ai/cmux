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

    func makeStore(holding macs: [HubDevice], account: String = "account-a") throws -> UserDefaults {
        let store = try #require(UserDefaults(suiteName: "screen-sharing-last-macs-\(UUID().uuidString)"))
        store.set(try JSONEncoder().encode(ScreenSharingPreferences.LastMacs(account: account, macs: macs)), forKey: lastMacsKey)
        return store
    }

    /// A hub that registered nothing and read no list yet: discovery is `finding`.
    func makeService(_ store: UserDefaults, account: String? = "account-a") -> ScreenSharingService {
        let identity = DeviceIdentity(deviceID: UUID(), keys: TestKeys())
        let client = DeviceHubClient(baseURL: URL(string: "https://hub.invalid")!, identity: identity,
                                     tokens: DeviceHubAccountToken { "token" })
        let hub = DeviceHub(client: client, secrets: MemoryRelaySecretStore(), deviceName: "iPhone", platform: .ios)
        let configuration = ScreenSharingService.Configuration(baseURL: URL(string: "https://hub.invalid")!, bundleIdentifier: "test",
                                                               deviceName: "iPhone", tokens: DeviceHubAccountToken { "token" },
                                                               accountID: account)
        return ScreenSharingService(hub: hub, configuration: configuration, preferences: ScreenSharingPreferences(store: store))
    }

    @Test func beforeTheListIsReadThePageDrawsTheLastListsMacs() throws {
        let phone = HubDevice(id: "phone", name: "Phone", platform: .ios, online: true)
        let service = makeService(try makeStore(holding: [studio(online: false), phone,
                                                          HubDevice(id: "mini", name: "Mini", platform: .macos, macScreenShared: true, online: true)]))
        #expect(service.discovery == .finding)
        #expect(service.macs.map(\.id) == ["mini", "studio"], "the last list's Macs, in list order, no phones")
    }

    /// Another account signed in on this phone (or none resolved yet): nothing of the last one shows.
    @Test func anotherAccountNeverSeesTheLastListsMacs() throws {
        let store = try makeStore(holding: [studio()])
        #expect(makeService(store, account: "account-b").macs.isEmpty)
        #expect(makeService(store, account: nil).macs.isEmpty)
    }

    /// The drawn state may be old: a tap waits for this list instead of acting on it.
    @Test func aTapOnALastListMacWaitsForTheList() throws {
        let service = makeService(try makeStore(holding: [studio(online: false)]))
        service.select(studio(online: false), scope: .full)
        #expect(service.alert == nil, "no 'offline' alert from the old list")
        #expect(service.viewer == nil)
        #expect(service.pendingSelection?.hostID == "studio")
        service.leaveUnshownRequest()
        #expect(service.pendingSelection == nil, "the page went away")
    }

    #if DEBUG
    /// The list is read: the waiting tap goes through against it, here to the read list's alert.
    @Test func aWaitingTapGoesThroughOnceTheListIsRead() throws {
        let service = makeService(try makeStore(holding: [studio()]))
        service.select(studio(), scope: .full)
        #expect(service.pendingSelection != nil)
        service.demoDiscovery = .listed
        service.demoMacs = [studio(online: false)]
        service.listChanged()
        #expect(service.pendingSelection == nil)
        #expect(service.alert?.refusal == .hostOffline, "the read list says it is offline now")

        let gone = makeService(try makeStore(holding: [studio()]))
        gone.select(studio(), scope: .full)
        gone.demoDiscovery = .listed
        gone.demoMacs = []
        gone.listChanged()
        #expect(gone.alert?.refusal == .notFound)
    }
    #endif

    @Test func theLastListIsKeptAndSigningOutForgetsIt() throws {
        let store = try makeStore(holding: [])
        let preferences = ScreenSharingPreferences(store: store)
        preferences.rememberMacs([studio()], for: "account-a")
        #expect(ScreenSharingPreferences(store: store).lastMacs(for: "account-a") == [studio()])
        let service = makeService(store)
        #expect(service.macs == [studio()])
        service.stop()
        #expect(ScreenSharingPreferences(store: store).lastMacs == nil)
        #expect(service.preferences.lastMacs == nil)
    }
}
#endif
