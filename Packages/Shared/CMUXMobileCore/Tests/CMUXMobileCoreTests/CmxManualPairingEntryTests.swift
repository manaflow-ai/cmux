import Foundation
import Testing

@testable import CMUXMobileCore

/// Coverage for the manual-entry route selection behind the pairing window's
/// "Copy IP" / "Copy Port" buttons.
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

    @Test func usesExplicitManualHostWhenNoTailscaleRouteExists() throws {
        let entry = CmxManualPairingEntry.best(in: [
            try route(id: "manual_host", kind: .manualHost, host: "studio-mac.corp.example", priority: 10),
        ])
        #expect(entry == CmxManualPairingEntry(host: "studio-mac.corp.example", port: 58465))
    }

    @Test func prefersTailscaleOverExplicitManualHostWhenBothExist() throws {
        let entry = CmxManualPairingEntry.best(in: [
            try route(id: "manual_host", kind: .manualHost, host: "192.168.4.12", priority: 10),
            try route(id: "tailscale", host: "100.64.0.5", priority: 20),
        ])
        #expect(entry == CmxManualPairingEntry(host: "100.64.0.5", port: 58465))
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
}
