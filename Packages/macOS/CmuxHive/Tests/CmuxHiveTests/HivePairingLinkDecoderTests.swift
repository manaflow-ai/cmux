import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxHive

@Suite struct HivePairingLinkDecoderTests {
    private func tailscaleTicket(macUserID: String? = "owner-1") throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-b",
            macDisplayName: "Studio",
            macUserID: macUserID,
            macPairingCompatibilityVersion: 0,
            routes: [
                // The canonical synthesized shape the v2 QR grammar requires
                // (id `tailscale`, priority 10), matching the Mac's resolver.
                try CmxAttachRoute(
                    id: "tailscale",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "100.64.0.7", port: 8123),
                    priority: 10
                )
            ],
            expiresAt: nil
        )
    }

    /// The v2 pairing URL another Mac's pairing window renders as its QR.
    private func pairingLink(macUserID: String? = "owner-1") throws -> String {
        let ticket = try tailscaleTicket(macUserID: macUserID)
        return try #require(CmxPairingQRCode().encode(ticket))
    }

    @Test func decodesSameAccountLink() throws {
        let decoder = HivePairingLinkDecoder(allowsLoopbackRoutes: false)
        let outcome = decoder.decode(try pairingLink(), currentStackUserID: "owner-1")
        guard case .ticket(let ticket) = outcome else {
            Issue.record("expected ticket, got \(outcome)")
            return
        }
        // The v2 grammar drops identity on purpose (it arrives post-handshake
        // from `mobile.host.status`), so the ticket names only the routes.
        #expect(ticket.macDeviceID.isEmpty)
        #expect(ticket.routes.count == 1)
        #expect(ticket.routes.first?.kind == .tailscale)
        #expect(ticket.routes.first?.endpoint == .hostPort(host: "100.64.0.7", port: 8123))
    }

    @Test func acceptsLinkWithoutAccountClaimOrLocalSession() throws {
        let decoder = HivePairingLinkDecoder(allowsLoopbackRoutes: false)
        // No user id in the link → the host enforces the account at RPC time.
        guard case .ticket = decoder.decode(try pairingLink(macUserID: nil), currentStackUserID: "owner-1") else {
            Issue.record("expected ticket for account-less link")
            return
        }
        // Signed out locally → defer to the host as well.
        guard case .ticket = decoder.decode(try pairingLink(), currentStackUserID: nil) else {
            Issue.record("expected ticket while signed out")
            return
        }
    }

    @Test func rejectsCrossAccountLink() throws {
        let decoder = HivePairingLinkDecoder(allowsLoopbackRoutes: false)
        let outcome = decoder.decode(try pairingLink(macUserID: "owner-1"), currentStackUserID: "someone-else")
        guard case .accountMismatch = outcome else {
            Issue.record("expected accountMismatch, got \(outcome)")
            return
        }
    }

    @Test func rejectsGarbageAndEmptyInput() {
        let decoder = HivePairingLinkDecoder(allowsLoopbackRoutes: false)
        guard case .invalidLink = decoder.decode("not a link", currentStackUserID: nil) else {
            Issue.record("expected invalidLink for garbage")
            return
        }
        guard case .invalidLink = decoder.decode("   ", currentStackUserID: nil) else {
            Issue.record("expected invalidLink for whitespace")
            return
        }
    }

    @Test func loopbackPolicyFollowsBuildChannel() throws {
        // Legacy compact payload keeps decoding loopback (the v2 grammar
        // rejects it inside the shared decoder), so the Mac-side policy is
        // what stands between a release build and dialing itself.
        let loopbackTicket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "mac-b",
            macDisplayName: "Same Machine",
            macPairingCompatibilityVersion: 0,
            routes: [
                try CmxAttachRoute(
                    id: "loop",
                    kind: .debugLoopback,
                    endpoint: .hostPort(host: "127.0.0.1", port: 8123)
                )
            ],
            expiresAt: nil
        )
        let payload = try CmxAttachTicketCompactCoder().encode(loopbackTicket)
        let base64 = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let link = "\(CmxPairingURLScheme.development)://attach?payload=\(base64)"

        let release = HivePairingLinkDecoder(allowsLoopbackRoutes: false)
        guard case .loopbackRejected = release.decode(link, currentStackUserID: nil) else {
            Issue.record("expected loopbackRejected in release policy")
            return
        }
        let dev = HivePairingLinkDecoder(allowsLoopbackRoutes: true)
        guard case .ticket(let ticket) = dev.decode(link, currentStackUserID: nil) else {
            Issue.record("expected ticket in dev policy")
            return
        }
        #expect(ticket.macDeviceID == "mac-b")
    }
}
