#if os(iOS) && DEBUG
import CmuxDeviceHub
import Foundation
import Testing
@testable import CmuxMobileScreenSharing

/// iOS release bar read-back, "Screen Sharing state matches Devices": in mock mode Settings ›
/// Devices listed the mock account's Macs while Screen Sharing said "Your Macs can't be reached ·
/// not signed in" (mock mode has no account token for the hub). `useMock` lists the same Macs.
@MainActor
@Suite struct ScreenSharingMockMacsTests {
    func makeService() -> ScreenSharingService {
        let configuration = ScreenSharingService.Configuration(baseURL: URL(string: "https://hub.invalid")!, bundleIdentifier: "test",
                                                               deviceName: "iPhone", tokens: DeviceHubAccountToken { "token" },
                                                               accountID: nil)
        return ScreenSharingService(configuration: configuration)
    }

    @Test func mockModeListsTheMockAccountsMacsAtOnce() async {
        var macs = [
            HubDevice(id: "studio", name: "Studio", platform: .macos, macScreenShared: true, online: false),
            HubDevice(id: "mbp", name: "MacBook Pro", platform: .macos, macScreenShared: true, online: true),
        ]
        let service = makeService()
        service.useMock { macs }
        #expect(service.discovery == .listed)
        // Online and sharing first, as the live list orders them.
        #expect(service.macs.map(\.id) == ["mbp", "studio"])
        #expect(service.unavailability(of: service.macs[0]) == nil)

        // Opening the page and pulling to refresh read the Macs again, never the hub.
        macs.append(HubDevice(id: "mini", name: "mini", platform: .macos, macScreenShared: true, online: true))
        service.start()
        #expect(service.discovery == .listed)
        #expect(service.macs.map(\.id) == ["mbp", "mini", "studio"])
        await service.refresh()
        #expect(service.macs.count == 3)
    }
}
#endif
