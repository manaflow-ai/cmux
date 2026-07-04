import Foundation
import Testing

@testable import CMUXMobileCore

/// Coverage for the manual-entry route selection behind the pairing window's
/// "Copy Address" button, and for the `host:port` display/parse round trip
/// shared with the phone's address box.
@Suite struct CmxManualPairingEntryTests {
    private func route(
        id: String,
        kind: CmxAttachTransportKind = .tailscale,
        host: String,
        port: Int = 58465,
        priority: Int
    ) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: kind,
            endpoint: .hostPort(host: host, port: port),
            priority: priority
        )
    }

    @Test func prefersTailscaleIPLiteralOverMagicDNSName() throws {
        // The Mac's route resolver emits the MagicDNS name first; the copy
        // buttons still surface the numeric IP, which works even when the
        // phone's DNS is not pointed at the tailnet.
        let entry = CmxManualPairingEntry.best(in: [
            try route(id: "tailscale", host: "lawrences-mac.tail1234.ts.net", priority: 10),
            try route(id: "tailscale_2", host: "100.64.0.5", priority: 20),
        ])
        #expect(entry == CmxManualPairingEntry(host: "100.64.0.5", port: 58465))
    }

    @Test func fallsBackToDNSNameWhenNoIPLiteralRoute() throws {
        let entry = CmxManualPairingEntry.best(in: [
            try route(id: "tailscale", host: "lawrences-mac.tail1234.ts.net", priority: 10),
        ])
        #expect(entry == CmxManualPairingEntry(host: "lawrences-mac.tail1234.ts.net", port: 58465))
    }

    @Test func skipsLoopbackRoutesEntirely() throws {
        // A DEBUG Mac's dev loopback route must never be offered for manual
        // phone entry, same rule as the QR encoder.
        let entry = CmxManualPairingEntry.best(in: [
            try route(id: "debug_loopback", kind: .debugLoopback, host: "127.0.0.1", priority: 0),
            try route(id: "tailscale", host: "100.64.0.5", priority: 10),
        ])
        #expect(entry == CmxManualPairingEntry(host: "100.64.0.5", port: 58465))
    }

    @Test func loopbackOnlyRoutesYieldNothing() throws {
        let entry = CmxManualPairingEntry.best(in: [
            try route(id: "debug_loopback", kind: .debugLoopback, host: "127.0.0.1", priority: 0),
            // A loopback host hiding under the tailscale kind is still loopback.
            try route(id: "tailscale", host: "127.0.0.1", priority: 10),
        ])
        #expect(entry == nil)
    }

    @Test func ipPreferenceRespectsPriorityOrderAmongLiterals() throws {
        let entry = CmxManualPairingEntry.best(in: [
            try route(id: "tailscale_2", host: "100.64.0.9", priority: 20),
            try route(id: "tailscale", host: "100.64.0.5", priority: 10),
        ])
        #expect(entry == CmxManualPairingEntry(host: "100.64.0.5", port: 58465))
    }

    @Test func emptyRoutesYieldNothing() {
        #expect(CmxManualPairingEntry.best(in: []) == nil)
    }

    @Test func displayStringJoinsHostAndPort() {
        #expect(CmxManualPairingEntry(host: "100.64.0.5", port: 58465).displayString == "100.64.0.5:58465")
        #expect(CmxManualPairingEntry(host: "mac.tail1234.ts.net", port: 1).displayString == "mac.tail1234.ts.net:1")
    }

    @Test func displayStringBracketsIPv6Hosts() {
        #expect(CmxManualPairingEntry(host: "fd7a:115c:a1e0::1", port: 58465).displayString == "[fd7a:115c:a1e0::1]:58465")
    }

    @Test func parseRoundTripsDisplayString() {
        let entries = [
            CmxManualPairingEntry(host: "100.64.0.5", port: 58465),
            CmxManualPairingEntry(host: "mac.tail1234.ts.net", port: 443),
            CmxManualPairingEntry(host: "fd7a:115c:a1e0::1", port: 58465),
        ]
        for entry in entries {
            #expect(CmxManualPairingEntry.parse(entry.displayString, defaultPort: 1) == entry)
        }
    }

    @Test func parseDefaultsPortWhenAbsent() {
        #expect(
            CmxManualPairingEntry.parse("  100.64.0.5  ", defaultPort: 58465)
                == CmxManualPairingEntry(host: "100.64.0.5", port: 58465)
        )
        #expect(
            CmxManualPairingEntry.parse("[fd7a::1]", defaultPort: 58465)
                == CmxManualPairingEntry(host: "fd7a::1", port: 58465)
        )
    }

    @Test func parseTreatsBracketlessIPv6AsHostOnly() {
        // Two or more colons can never be a host:port split, so the whole
        // string is the host and the port falls back to the default.
        #expect(
            CmxManualPairingEntry.parse("fd7a:115c:a1e0::1", defaultPort: 58465)
                == CmxManualPairingEntry(host: "fd7a:115c:a1e0::1", port: 58465)
        )
    }

    @Test func parseRejectsBadPorts() {
        #expect(CmxManualPairingEntry.parse("100.64.0.5:70000", defaultPort: 1) == nil)
        #expect(CmxManualPairingEntry.parse("100.64.0.5:0", defaultPort: 1) == nil)
        #expect(CmxManualPairingEntry.parse("100.64.0.5:", defaultPort: 1) == nil)
        #expect(CmxManualPairingEntry.parse("100.64.0.5:abc", defaultPort: 1) == nil)
        #expect(CmxManualPairingEntry.parse("[fd7a::1]:99999", defaultPort: 1) == nil)
    }

    @Test func parseRejectsMalformedShapes() {
        #expect(CmxManualPairingEntry.parse("", defaultPort: 1) == nil)
        #expect(CmxManualPairingEntry.parse("   ", defaultPort: 1) == nil)
        #expect(CmxManualPairingEntry.parse("[fd7a::1", defaultPort: 1) == nil)
        #expect(CmxManualPairingEntry.parse("[]:58465", defaultPort: 1) == nil)
        #expect(CmxManualPairingEntry.parse(":58465", defaultPort: 1) == nil)
        #expect(CmxManualPairingEntry.parse("[fd7a::1]58465", defaultPort: 1) == nil)
    }
}
