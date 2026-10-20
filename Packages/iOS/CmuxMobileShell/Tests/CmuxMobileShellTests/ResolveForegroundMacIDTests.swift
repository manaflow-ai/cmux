import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

/// The foreground-Mac key decides which per-Mac bucket the connected Mac's
/// workspaces land in. The stored-Mac reconnect path passes the SAVED Mac's id
/// as a hint while dialing that Mac's persisted routes; a stale route can be
/// answered by a DIFFERENT Mac, whose minted ticket carries its own real id.
/// The ticket's real id must win then — ticket persistence already keys by it,
/// so letting the hint win splits the identity (workspaces under the saved Mac,
/// persistence under the answering Mac). The hint exists only to key synthetic
/// `manual-…` fallback tickets and id-less minimal pairing tickets.
@Suite struct ResolveForegroundMacIDTests {
    private func ticket(macDeviceID: String) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "workspace-1",
            terminalID: "terminal-1",
            macDeviceID: macDeviceID,
            macDisplayName: "Test Mac",
            routes: [
                try CmxAttachRoute(
                    id: "tailscale",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "100.82.214.112", port: 50906),
                    priority: 10
                ),
            ],
            expiresAt: Date().addingTimeInterval(60)
        )
    }

    @Test func realTicketIDWinsOverContradictingStoredHint() throws {
        #expect(try ticket(macDeviceID: "mac-b").foregroundMacID(hint: "mac-a") == "mac-b")
    }

    @Test func hintKeysSyntheticManualFallbackTicket() throws {
        #expect(try ticket(macDeviceID: "manual-ticket-request").foregroundMacID(hint: "mac-a") == "mac-a")
    }

    @Test func ticketIDUsedWithoutHint() throws {
        #expect(try ticket(macDeviceID: "mac-b").foregroundMacID(hint: nil) == "mac-b")
    }

    @Test func syntheticHintNeverKeysARealTicket() throws {
        #expect(try ticket(macDeviceID: "mac-b").foregroundMacID(hint: "manual-xyz") == "mac-b")
    }
}
