import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

/// Account-binding preflight for scanned pairing links.
///
/// The scanner accepts pairing URLs from every channel. Preflight therefore
/// enforces only the actual account binding carried by the ticket and does not
/// reject a QR because the link scheme came from a dev, beta, nightly, or stable
/// build. Dev reloads that need to pair with real Macs now run production auth
/// by default, so matching production Stack user ids pass just like release
/// builds.
@MainActor
@Suite struct MobilePairingAccountPreflightTests {
    private func ticket(macUserID: String? = nil, macUserEmail: String? = nil) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "test-mac",
            macDisplayName: "Test Mac",
            macUserEmail: macUserEmail,
            macUserID: macUserID,
            routes: [
                CmxAttachRoute(
                    id: "tailscale",
                    kind: .tailscale,
                    endpoint: .hostPort(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort)
                ),
            ]
        )
    }

    @Test func matchingUserIDsProceedWithoutConsultingPairingScheme() throws {
        let category = MobilePairingAccountPreflight(
            actualUserID: "user-1",
            actualEmail: "same@example.com"
        ).failure(for: try ticket(macUserID: "user-1"))

        #expect(category == nil)
    }

    @Test func userIDMismatchIsAuthFailedWithoutChannelRestrictionCopy() throws {
        let category = MobilePairingAccountPreflight(
            actualUserID: "user-b",
            actualEmail: "same@example.com"
        ).failure(for: try ticket(macUserID: "user-a"))

        #expect(category == .authFailed)
        #expect(category?.analyticsReason == "auth")
        #expect(category?.isAuthorizationFailure == true)
    }

    @Test func unknownLocalIdentityStillLetsHostVerificationOwnRejection() throws {
        let category = MobilePairingAccountPreflight(
            actualUserID: nil,
            actualEmail: nil
        ).failure(for: try ticket(macUserID: "prod-user-id"))

        #expect(category == nil)
    }

    @Test func legacyEmailTicketKeepsEmailMismatch() throws {
        let category = MobilePairingAccountPreflight(
            actualUserID: nil,
            actualEmail: "phone@example.com"
        ).failure(for: try ticket(macUserEmail: "mac@example.com"))

        #expect(category == .emailMismatch(expected: "mac@example.com", actual: "phone@example.com"))
    }

    @Test func legacyEmailTicketMatchesCaseInsensitively() throws {
        let category = MobilePairingAccountPreflight(
            actualUserID: nil,
            actualEmail: " Phone@Example.COM "
        ).failure(for: try ticket(macUserEmail: "phone@example.com"))

        #expect(category == nil)
    }
}
