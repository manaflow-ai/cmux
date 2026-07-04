import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

/// Account-binding preflight for scanned pairing links.
///
/// The scanner accepts pairing URLs from every channel. Preflight therefore
/// never rejects a QR just because the link scheme came from a dev, beta,
/// nightly, or stable build. It uses the scheme only to explain an already
/// failed account binding when the two Stack projects are known to differ.
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

    @Test func matchingUserIDsProceedEvenWhenChannelsDiffer() throws {
        let category = MobilePairingAccountPreflight(
            scannedScheme: CmxPairingURLScheme.release,
            actualUserID: "user-1",
            actualEmail: "same@example.com",
            isDevelopmentAuthEnvironment: true
        ).failure(for: try ticket(macUserID: "user-1"))

        #expect(category == nil)
    }

    @Test func devPhoneScanningReleaseMacQRMismatchNamesTheAuthEnvironment() throws {
        let category = MobilePairingAccountPreflight(
            scannedScheme: CmxPairingURLScheme.release,
            actualUserID: "dev-user-id",
            actualEmail: "same@example.com",
            isDevelopmentAuthEnvironment: true
        ).failure(for: try ticket(macUserID: "prod-user-id"))

        #expect(category == .authEnvironmentMismatch(macChannelIsRelease: true))
        #expect(category?.analyticsReason == "auth_environment_mismatch")
        #expect(category?.isAuthorizationFailure == false)
    }

    @Test func prodPhoneScanningDevMacQRMismatchNamesTheAuthEnvironment() throws {
        let category = MobilePairingAccountPreflight(
            scannedScheme: CmxPairingURLScheme.development,
            actualUserID: "prod-user-id",
            actualEmail: "same@example.com",
            isDevelopmentAuthEnvironment: false
        ).failure(for: try ticket(macUserID: "dev-user-id"))

        #expect(category == .authEnvironmentMismatch(macChannelIsRelease: false))
        #expect(category?.analyticsReason == "auth_environment_mismatch")
        #expect(category?.isAuthorizationFailure == false)
    }

    @Test func sameChannelUserIDMismatchIsAuthFailed() throws {
        let category = MobilePairingAccountPreflight(
            scannedScheme: CmxPairingURLScheme.release,
            actualUserID: "user-b",
            actualEmail: "same@example.com",
            isDevelopmentAuthEnvironment: false
        ).failure(for: try ticket(macUserID: "user-a"))

        #expect(category == .authFailed)
        #expect(category?.analyticsReason == "auth")
        #expect(category?.isAuthorizationFailure == true)
    }

    @Test func unknownLocalIdentityStillLetsHostVerificationOwnRejection() throws {
        let category = MobilePairingAccountPreflight(
            scannedScheme: CmxPairingURLScheme.release,
            actualUserID: nil,
            actualEmail: nil,
            isDevelopmentAuthEnvironment: true
        ).failure(for: try ticket(macUserID: "prod-user-id"))

        #expect(category == nil)
    }

    @Test func legacyEmailTicketKeepsEmailMismatch() throws {
        let category = MobilePairingAccountPreflight(
            scannedScheme: CmxPairingURLScheme.release,
            actualUserID: nil,
            actualEmail: "phone@example.com",
            isDevelopmentAuthEnvironment: false
        ).failure(for: try ticket(macUserEmail: "mac@example.com"))

        #expect(category == .emailMismatch(expected: "mac@example.com", actual: "phone@example.com"))
    }

    @Test func legacyEmailTicketMatchesCaseInsensitively() throws {
        let category = MobilePairingAccountPreflight(
            scannedScheme: CmxPairingURLScheme.release,
            actualUserID: nil,
            actualEmail: " Phone@Example.COM ",
            isDevelopmentAuthEnvironment: false
        ).failure(for: try ticket(macUserEmail: "phone@example.com"))

        #expect(category == nil)
    }
}
