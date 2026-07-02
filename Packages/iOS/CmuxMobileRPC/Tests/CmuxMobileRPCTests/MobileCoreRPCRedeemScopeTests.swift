import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

/// Scope-merge safety for redeemed attach tickets. A redeem reply that omits its
/// own workspace/terminal scope must fall back to the scanned scope rather than
/// widening the effective ticket, while a reply that carries its own scope still
/// takes precedence over the scan.
struct MobileCoreRPCRedeemScopeTests {
    private func makeClient(scanned: CmxAttachTicket, route: CmxAttachRoute) -> MobileCoreRPCClient {
        MobileCoreRPCClient(
            runtime: TestMobileSyncRuntime(
                transportFactory: ScriptedRPCTransportFactory(
                    transport: ScriptedRPCTransport { _ in [String: Any]() }
                )
            ),
            route: route,
            ticket: scanned,
            allowsStackAuthFallback: true
        )
    }

    @Test func emptyReplyScopeFallsBackToScannedScope() throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465, priority: 10)
        let scanned = try CmxAttachTicket(
            workspaceID: "ws-scanned",
            terminalID: "term-scanned",
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: nil,
            ticketRef: "ticket-ref-123",
            authToken: nil
        )
        let client = makeClient(scanned: scanned, route: route)

        // Reply carries an empty workspace and a whitespace-only terminal: both are
        // gaps that must not broaden the ticket past the scanned scope.
        let emptyScopeReply = try CmxAttachTicket(
            workspaceID: "   ",
            terminalID: "  ",
            macDeviceID: "mac-1",
            macDisplayName: "Studio",
            routes: [route],
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
            ticketRef: "ticket-ref-123",
            authToken: "ticket-secret"
        )
        let merged = try client.redeemedTicket(
            emptyScopeReply,
            ticketRef: "ticket-ref-123",
            constrainedTo: scanned
        )
        #expect(merged.workspaceID == "ws-scanned")
        #expect(merged.terminalID == "term-scanned")
        // Non-scope reply fields are still preferred from the redeemed ticket.
        #expect(merged.authToken == "ticket-secret")
        #expect(merged.macDeviceID == "mac-1")
        #expect(merged.macDisplayName == "Studio")
    }

    @Test func replyScopeTakesPrecedenceOverScannedScope() throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465, priority: 10)
        let scanned = try CmxAttachTicket(
            workspaceID: "ws-scanned",
            terminalID: "term-scanned",
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: nil,
            ticketRef: "ticket-ref-123",
            authToken: nil
        )
        let client = makeClient(scanned: scanned, route: route)

        let scopedReply = try CmxAttachTicket(
            workspaceID: "ws-redeemed",
            terminalID: "term-redeemed",
            macDeviceID: "mac-1",
            macDisplayName: "Studio",
            routes: [route],
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
            ticketRef: "ticket-ref-123",
            authToken: "ticket-secret"
        )
        let merged = try client.redeemedTicket(
            scopedReply,
            ticketRef: "ticket-ref-123",
            constrainedTo: scanned
        )
        #expect(merged.workspaceID == "ws-redeemed")
        #expect(merged.terminalID == "term-redeemed")
    }
}
