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

    @Test func launchWithNoNetworkIsLostThenChangedWhenItComes() {
        var filter = NetworkPathFilter()
        #expect(filter.update(satisfied: false, signature: "") == .lost)
        #expect(filter.update(satisfied: false, signature: "") == nil)
        #expect(filter.update(satisfied: true, signature: "en0 via 192.168.1.1") == .changed("en0 via 192.168.1.1"))
    }

    @Test func airplaneModeIsLostThenChangedOnReturn() {
        var filter = NetworkPathFilter()
        _ = filter.update(satisfied: true, signature: "en0 via 192.168.1.1")
        #expect(filter.update(satisfied: false, signature: "") == .lost)
        #expect(filter.update(satisfied: false, signature: "") == nil)
        // Back on the same Wi-Fi: still a change (the old sockets are gone).
        #expect(filter.update(satisfied: true, signature: "en0 via 192.168.1.1") == .changed("en0 via 192.168.1.1"))
    }

    /// A healthy Wi-Fi whose secondary interfaces come and go (a USB link to the Mac, a cellular
    /// context, a VPN's utun) is one network: no change, so no roam. a153's phone, plugged into
    /// the Mac, roamed 183 times in 20 minutes on these.
    @Test func secondaryInterfacesComingAndGoingAreNotAChange() {
        let gateways = ["192.168.1.1:0", "fe80::1%en0:0"]
        let lists: [[String]] = [
            ["en0", "pdp_ip0"], ["en0", "pdp_ip0", "en2"], ["en0"], ["en0", "utun4", "pdp_ip0"],
            ["en0", "en2", "anpi0"], ["en0", "pdp_ip1", "pdp_ip0"], ["en0", "pdp_ip0"],
        ]
        var filter = NetworkPathFilter()
        var events: [NetworkPathEvent] = []
        for _ in 0..<30 {
            for interfaces in lists {
                // The OS lists gateways in any order; the route is the same.
                for order in [gateways, gateways.reversed()] {
                    if let event = filter.update(satisfied: true, signature: NetworkPathFilter.signature(interfaces: interfaces, gateways: order)) {
                        events.append(event)
                    }
                }
            }
        }
        #expect(events.isEmpty)
    }

    @Test func theRouteOutChangingIsStillAChange() {
        var filter = NetworkPathFilter()
        let home = NetworkPathFilter.signature(interfaces: ["en0", "pdp_ip0"], gateways: ["192.168.1.1:0"])
        #expect(filter.update(satisfied: true, signature: home) == nil)
        // Wi-Fi gone: cellular is the route.
        let cell = NetworkPathFilter.signature(interfaces: ["pdp_ip0"], gateways: [])
        #expect(filter.update(satisfied: true, signature: cell) == .changed(cell))
        // Another Wi-Fi: same interface, another gateway.
        let cafe = NetworkPathFilter.signature(interfaces: ["en0", "pdp_ip0"], gateways: ["10.0.0.1:0"])
        #expect(filter.update(satisfied: true, signature: cafe) == .changed(cafe))
        // A full-tunnel VPN takes the route.
        let vpn = NetworkPathFilter.signature(interfaces: ["utun4", "en0"], gateways: ["10.0.0.1:0"])
        #expect(filter.update(satisfied: true, signature: vpn) == .changed(vpn))
    }

    @Test func secondaryCellularDoesNotTurnWifiIntoLte() {
        // NWPath can report both interfaces as available. Only the preferred
        // one carries the route and should drive Ultra Auto and telemetry.
        #expect(NetworkPathFilter.networkKind(preferredCellular: false,
                                              preferredWiFi: true,
                                              preferredWired: false) == "wifi")
        #expect(NetworkPathFilter.networkKind(preferredCellular: true,
                                              preferredWiFi: false,
                                              preferredWired: false) == "lte")
    }
}
