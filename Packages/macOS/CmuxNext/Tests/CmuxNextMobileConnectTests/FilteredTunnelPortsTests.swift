import CmuxMobileHost
import CmuxMobileWire
@testable import CmuxNextMobileConnect
import Testing

@Suite("tunnel ports")
struct FilteredTunnelPortsTests {
    @Test func thisMacsOwnListenersAreNeverAdvertised() async {
        let base = StaticTunnelPorts([TunnelPort(port: 3000, source: .detected), TunnelPort(port: 47811, source: .detected),
                                      TunnelPort(port: 8080, source: .allowed)])
        let ports = FilteredTunnelPorts(base: base) { [47811] }
        let principal = MobileDevicePrincipal(install: "in_phone1", userID: "u_alice", platform: "ios", appVersion: "1.0")
        #expect(await ports.ports(for: principal).map(\.port) == [3000, 8080])
    }
}
