import CmuxNextCloudTunnel
import Testing

/// The packet tunnel rebinds only on a real path change, never on the monitor's first path.
@Suite struct CloudTunnelPathChangeGateTests {
    @Test func theFirstPathIsNotAChange() {
        var gate = CloudTunnelPathChangeGate<String>()
        let first = gate.admit("wifi")
        #expect(!first)
    }

    @Test func aRepeatedPathIsNotAChange() {
        var gate = CloudTunnelPathChangeGate<String>()
        let changes = ["wifi", "wifi", "wifi"].map { gate.admit($0) }
        #expect(changes == [false, false, false])
    }

    @Test func eachRealChangePassesOnce() {
        var gate = CloudTunnelPathChangeGate<String>()
        let changes = ["wifi", "ethernet", "ethernet", "wifi", "none", "none", "wifi"].map { gate.admit($0) }
        #expect(changes == [false, true, false, true, true, false, true])
    }
}
