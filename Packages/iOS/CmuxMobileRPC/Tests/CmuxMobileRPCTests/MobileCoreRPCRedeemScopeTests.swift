import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

/// Scope-merge safety for redeemed attach tickets. The scanned QR scope is
/// authoritative: a redeem reply may fill a scanned gap (the compact `v=3`
/// grammar always scans empty scope) but must never widen the ticket with empty
/// scope, nor retarget it to a different non-empty workspace/terminal than was
/// scanned.
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

    private func scannedTicket(
        workspaceID: String,
        terminalID: String?,
        route: CmxAttachRoute
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: "",
            macDisplayName: nil,
            routes: [route],
            expiresAt: nil,
            ticketRef: "ticket-ref-123",
            authToken: nil
        )
    }

    /// Empty/whitespace redeemed scope is a gap: fall back to the non-empty scanned
    /// scope rather than storing an empty workspace/terminal.
    @Test func emptyReplyScopeFallsBackToScannedScope() throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465, priority: 10)
        let scanned = try scannedTicket(workspaceID: "ws-scanned", terminalID: "term-scanned", route: route)
        let client = makeClient(scanned: scanned, route: route)

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

    /// A redeem reply that carries a *different* non-empty scope must not retarget
    /// the ticket: the scanned QR scope the user consented to stays authoritative.
    @Test func mismatchedReplyScopeFallsBackToScannedScope() throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465, priority: 10)
        let scanned = try scannedTicket(workspaceID: "ws-scanned", terminalID: "term-scanned", route: route)
        let client = makeClient(scanned: scanned, route: route)

        let mismatchedReply = try CmxAttachTicket(
            workspaceID: "ws-other",
            terminalID: "term-other",
            macDeviceID: "mac-1",
            macDisplayName: "Studio",
            routes: [route],
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
            ticketRef: "ticket-ref-123",
            authToken: "ticket-secret"
        )
        let merged = try client.redeemedTicket(
            mismatchedReply,
            ticketRef: "ticket-ref-123",
            constrainedTo: scanned
        )
        #expect(merged.workspaceID == "ws-scanned")
        #expect(merged.terminalID == "term-scanned")
        // Non-scope reply fields are still preferred from the redeemed ticket.
        #expect(merged.authToken == "ticket-secret")
        #expect(merged.macDeviceID == "mac-1")
    }

    /// The compact `v=3` flow: the QR scans empty scope, so the redeemed reply is the
    /// only source of workspace/terminal and its non-empty scope fills the scanned gap.
    @Test func emptyScannedScopeAdoptsRedeemedScope() throws {
        let route = try hostPortRoute(kind: .tailscale, host: "100.64.0.5", port: 58465, priority: 10)
        let scanned = try scannedTicket(workspaceID: "", terminalID: nil, route: route)
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
