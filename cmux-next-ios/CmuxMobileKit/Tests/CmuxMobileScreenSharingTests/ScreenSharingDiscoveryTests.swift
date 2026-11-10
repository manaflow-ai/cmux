#if os(iOS)
import CmuxDeviceHub
import Testing
@testable import CmuxMobileScreenSharing

/// CMUX-13: the Macs list never says "No Macs" while it is still looking. The hub is
/// `ready` once this phone registers, before the socket reads the device list.
@Suite struct ScreenSharingDiscoveryTests {
    typealias Service = ScreenSharingService

    @Test func registeredButNotYetListedIsStillFinding() {
        for connection: DeviceHubSocket.State in [.disconnected, .connecting, .connected, .reconnecting("timeout")] {
            #expect(Service.discovery(status: .ready, listed: false, listError: nil, connection: connection) == .finding)
        }
    }

    @Test func startingIsFinding() {
        #expect(Service.discovery(status: .idle, listed: false, listError: nil, connection: .disconnected) == .finding)
        #expect(Service.discovery(status: .starting, listed: false, listError: nil, connection: .disconnected) == .finding)
    }

    @Test func aReadListIsListedEvenWhenEmptyOrRestarting() {
        #expect(Service.discovery(status: .ready, listed: true, listError: nil, connection: .connected) == .listed)
        #expect(Service.discovery(status: .starting, listed: true, listError: nil, connection: .disconnected) == .listed)
        // A later failed refresh keeps the list it read.
        #expect(Service.discovery(status: .ready, listed: true, listError: "down", connection: .connected) == .listed)
    }

    @Test func failuresSayWhyInsteadOfSpinning() {
        #expect(Service.discovery(status: .failed("no network"), listed: false, listError: nil, connection: .disconnected) == .failed("no network"))
        #expect(Service.discovery(status: .ready, listed: false, listError: "down", connection: .connected) == .failed("down"))
        for connection: DeviceHubSocket.State in [.replaced, .removed, .signedOut] {
            guard case .failed = Service.discovery(status: .ready, listed: false, listError: nil, connection: connection) else {
                Issue.record("\(connection) should fail"); continue
            }
        }
    }
}
#endif
