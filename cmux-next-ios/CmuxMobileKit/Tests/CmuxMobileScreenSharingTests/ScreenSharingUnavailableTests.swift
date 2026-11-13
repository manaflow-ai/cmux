#if os(iOS)
import CmuxDeviceHub
import Testing
@testable import CmuxMobileScreenSharing

/// A Mac that can't be shared says why in an alert when it's tapped (user 2026-11-13), never as
/// a full-screen card over the list, and + › Screen Sharing never connects to it on its own.
@Suite struct ScreenSharingUnavailableTests {
    typealias Service = ScreenSharingService

    private func mac(_ name: String = "Aziz's MacBook Pro", id: String = "mbp", shared: Bool = true, online: Bool = true) -> HubDevice {
        HubDevice(id: id, name: name, platform: .macos, macScreenShared: shared, online: online)
    }

    @Test func reasonOfEachUnavailableMac() {
        #expect(Service.unavailability(of: mac(shared: false), access: .full) == .notShared)
        #expect(Service.unavailability(of: mac(online: false), access: .full) == .hostOffline)
        #expect(Service.unavailability(of: mac(), access: .none) == .permissionNone)
        // Offline wins: a Mac that's off can't say whether it shares or whom it allows.
        #expect(Service.unavailability(of: mac(shared: false, online: false), access: .none) == .hostOffline)
        #expect(Service.unavailability(of: mac(shared: false), access: .none) == .notShared)
    }

    @Test func sharingMacIsAvailableAtEveryAccessButNone() {
        for access: DeviceScope in [.ask, .view, .full] {
            #expect(Service.unavailability(of: mac(), access: access) == nil)
        }
    }

    @Test func plusScreenSharingConnectsOnlyToAMacThatCanBeShared() {
        let reason: @Sendable (HubDevice) -> ScreenSharingRefusal? = { Service.unavailability(of: $0, access: .full) }
        let notShared = mac(shared: false)
        #expect(ScreenSharingPage.namedMac("Aziz's MacBook Pro", in: [notShared], unavailable: reason) == nil)
        #expect(ScreenSharingPage.namedMac("Aziz's MacBook Pro", in: [mac(online: false)], unavailable: reason) == nil)
        #expect(ScreenSharingPage.namedMac("aziz\u{2019}s macbook pro", in: [mac()], unavailable: reason)?.id == "mbp")
        // Two Macs with the name: the list decides.
        #expect(ScreenSharingPage.namedMac("Aziz's MacBook Pro", in: [mac(), mac(id: "other")], unavailable: reason) == nil)
        #expect(ScreenSharingPage.namedMac(nil, in: [mac()], unavailable: reason) == nil)
    }

    @Test func aRequestFromTheListGoesFullScreenOnlyOnceTheHubAnswers() {
        #expect(!ScreenSharingViewer.Phase.idle.goesFullScreen)
        #expect(!ScreenSharingViewer.Phase.requesting(.full).goesFullScreen)
        #expect(!ScreenSharingViewer.Phase.refused(.notShared, requested: .full).goesFullScreen)
        #expect(ScreenSharingViewer.Phase.waitingForApproval(sessionID: "s", scope: .full).goesFullScreen)
        #expect(ScreenSharingViewer.Phase.approved(sessionID: "s", scope: .full).goesFullScreen)
        #expect(ScreenSharingViewer.Phase.streaming(sessionID: "s", scope: .full).goesFullScreen)
        #expect(ScreenSharingViewer.Phase.declined(.full).goesFullScreen)
        #expect(ScreenSharingViewer.Phase.ended(reason: nil).goesFullScreen)
    }
}
#endif
