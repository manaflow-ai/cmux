import Testing
@testable import CmuxMobileTransport

@Suite struct NetworkPathFilterTests {
    @Test func firstPathIsTheStartNotAChange() {
        var filter = NetworkPathFilter()
        #expect(filter.update(satisfied: true, signature: "en0 via 192.168.1.1") == nil)
        #expect(filter.update(satisfied: true, signature: "en0 via 192.168.1.1") == nil)
    }

    @Test func wifiToCellularAndAnotherWifiAreChanges() {
        var filter = NetworkPathFilter()
        _ = filter.update(satisfied: true, signature: "en0 via 192.168.1.1")
        #expect(filter.update(satisfied: true, signature: "pdp_ip0 via ") == .changed("pdp_ip0 via "))
        #expect(filter.update(satisfied: true, signature: "en0 via 10.0.0.1") == .changed("en0 via 10.0.0.1"))
    }

    @Test func airplaneModeIsLostThenChangedOnReturn() {
        var filter = NetworkPathFilter()
        _ = filter.update(satisfied: true, signature: "en0 via 192.168.1.1")
        #expect(filter.update(satisfied: false, signature: "") == .lost)
        #expect(filter.update(satisfied: false, signature: "") == nil)
        // Back on the same Wi-Fi: still a change (the old sockets are gone).
        #expect(filter.update(satisfied: true, signature: "en0 via 192.168.1.1") == .changed("en0 via 192.168.1.1"))
    }
}
