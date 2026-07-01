import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileShell

/// Tests the single pairing-failure classifier that turns any thrown error into
/// a distinct, user-visible category. This is the spine of the fix for the
/// silent-revert pairing bug: every failed attempt resolves to exactly one
/// category with a non-empty headline, a stable analytics reason, and
/// (for the reachability cases) an actionable guidance line. The classifier is a
/// pure function so this verifies the whole "error -> what the user reads"
/// contract without a live connection.
@Suite struct MobilePairingFailureTests {
    private func route(
        host: String = "100.71.210.41",
        port: Int = CmxMobileDefaults.defaultHostPort
    ) throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: "tailscale",
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    // MARK: - Transport-level classification

    @Test func hostUnreachableClassifiesAndKeepsHostInMessage() throws {
        let route = try route(host: "100.99.1.2", port: 58_465)
        let category = MobilePairingFailureCategory.classify(
            error: CmxNetworkByteTransportError.connectionFailed("no route", .hostUnreachable),
            route: route
        )
        #expect(category == .hostUnreachable(host: "100.99.1.2", port: 58_465))
        #expect(category.analyticsReason == "host_unreachable")
        #expect(category.message.contains("100.99.1.2"))
        #expect(category.message.contains("58465"))
        // The dominant no-Tailscale case must give actionable reachability guidance.
        #expect(category.guidance != nil)
    }

    @Test func connectionRefusedMeansListenerNotRunning() throws {
        let category = MobilePairingFailureCategory.classify(
            error: CmxNetworkByteTransportError.connectionFailed("refused", .connectionRefused),
            route: try route()
        )
        #expect(category == .listenerNotRunning(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort))
        #expect(category.analyticsReason == "listener_not_running")
        #expect(category.message.lowercased().contains("cmux"))
        #expect(category.guidance != nil)
    }

    @Test func permissionDeniedMapsToLocalNetworkBlocked() throws {
        let category = MobilePairingFailureCategory.classify(
            error: CmxNetworkByteTransportError.connectionFailed("blocked", .permissionDenied),
            route: try route()
        )
        #expect(category == .localNetworkBlocked)
        #expect(category.analyticsReason == "local_network_blocked")
        #expect(!category.message.isEmpty)
        #expect(category.guidance != nil)
    }

    @Test func dnsFailureKeepsHostButNotPort() throws {
        let category = MobilePairingFailureCategory.classify(
            error: CmxNetworkByteTransportError.connectionFailed("dns", .dnsFailed),
            route: try route(host: "my-mac.tail.ts.net")
        )
        #expect(category == .dnsFailed(host: "my-mac.tail.ts.net", port: CmxMobileDefaults.defaultHostPort))
        #expect(category.analyticsReason == "dns_failed")
        #expect(category.message.contains("my-mac.tail.ts.net"))
    }

    @Test func connectTimeoutClassifiesAsHandshakeTimeout() throws {
        let category = MobilePairingFailureCategory.classify(
            error: CmxNetworkByteTransportError.connectionTimedOut,
            route: try route()
        )
        #expect(category == .handshakeTimedOut(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort))
        #expect(category.analyticsReason == "timeout")
        #expect(category.guidance != nil)
    }

    @Test func receiveFailureMeansConnectionDropped() throws {
        let category = MobilePairingFailureCategory.classify(
            error: CmxNetworkByteTransportError.receiveFailed("eof"),
            route: try route()
        )
        #expect(category == .connectionDropped(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort))
        #expect(category.analyticsReason == "connection_dropped")
    }

    // MARK: - RPC-level classification

    @Test func requestTimeoutClassifiesAsHandshakeTimeout() throws {
        let category = MobilePairingFailureCategory.classify(
            error: MobileShellConnectionError.requestTimedOut,
            route: try route()
        )
        #expect(category == .handshakeTimedOut(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort))
        #expect(category.analyticsReason == "timeout")
    }

    @Test func expiredTicketIsAuthorizationFailureNeedingRescan() {
        let category = MobilePairingFailureCategory.classify(
            error: MobileShellConnectionError.attachTicketExpired,
            route: nil
        )
        #expect(category == .ticketExpired)
        #expect(category.analyticsReason == "ticket_expired")
        #expect(category.isAuthorizationFailure)
    }

    @Test func accountMismatchIsAuthorizationFailure() {
        let category = MobilePairingFailureCategory.classify(
            error: MobileShellConnectionError.accountMismatch("different account"),
            route: nil
        )
        #expect(category == .accountMismatch)
        #expect(category.analyticsReason == "account_mismatch")
        #expect(category.isAuthorizationFailure)
    }

    @Test func emailMismatchIsAuthorizationFailure() {
        let category = MobilePairingFailureCategory.emailMismatch(
            expected: "mac@example.com",
            actual: "phone@example.com"
        )
        #expect(category.analyticsReason == "email_mismatch")
        #expect(category.isAuthorizationFailure)
        #expect(category.message.contains("mac@example.com"))
        #expect(category.message.contains("phone@example.com"))
    }

    @Test func insecureManualRouteIsUnsupportedRoute() {
        let category = MobilePairingFailureCategory.classify(
            error: MobileShellConnectionError.insecureManualRoute,
            route: nil
        )
        #expect(category == .unsupportedRoute)
        #expect(category.analyticsReason == "unsupported_route")
    }

    @Test func authEnvironmentMismatchTellsTheTruthAboutTheChannel() {
        // A dev-channel build failing a release Mac's QR user-id binding: the
        // emails DO match, so the copy must name the auth-environment cause and
        // the --prod-auth remedy instead of the authFailed "same email" advice
        // (https://github.com/manaflow-ai/cmux/issues/7145).
        let category = MobilePairingFailureCategory.authEnvironmentMismatch
        #expect(category.analyticsReason == "auth_environment_mismatch")
        #expect(category.message.contains("development auth environment"))
        #expect(category.message != MobilePairingFailureCategory.authFailed.message)
        #expect(!category.message.contains("Make sure both devices are signed in"))
        #expect(category.guidance?.contains("--prod-auth") == true)
        // Signing out cannot move the account to another Stack project, so this
        // must not drive the re-auth (Sign Out) prompt.
        #expect(!category.isAuthorizationFailure)
    }

    @Test func rpcUnauthorizedCodeMapsToAuthFailed() {
        let category = MobilePairingFailureCategory.classify(
            error: MobileShellConnectionError.rpcError("unauthorized", "nope"),
            route: nil
        )
        #expect(category == .authFailed)
        #expect(category.analyticsReason == "auth")
    }

    @Test func rpcAccountMismatchCodeMapsToAccountMismatch() {
        let category = MobilePairingFailureCategory.classify(
            error: MobileShellConnectionError.rpcError("account_mismatch", "different"),
            route: nil
        )
        #expect(category == .accountMismatch)
    }

    @Test func unrecognizedRPCErrorIsActionableUnknownNotEmpty() throws {
        let category = MobilePairingFailureCategory.classify(
            error: MobileShellConnectionError.rpcError("weird_code", "something odd"),
            route: try route()
        )
        #expect(category == .unknown(host: "100.71.210.41", port: CmxMobileDefaults.defaultHostPort))
        #expect(category.analyticsReason == "other")
        // The core regression guarantee: even an unrecognized failure produces a
        // non-empty headline, so the spinner can never revert with no message.
        #expect(!category.message.isEmpty)
    }

    // MARK: - Cancellation and offline

    @Test func cancellationClassifiesAsCancelledWithNoMessage() {
        let category = MobilePairingFailureCategory.classify(
            error: CancellationError(),
            route: nil
        )
        #expect(category == .cancelled)
        #expect(category.analyticsReason == "cancelled")
        // Cancellation is the only category with an intentionally empty headline.
        #expect(category.message.isEmpty)
    }

    @Test func offlineCategoryHasNonEmptyMessage() {
        let category = MobilePairingFailureCategory.offline
        #expect(category.analyticsReason == "offline")
        #expect(!category.message.isEmpty)
    }

    @Test func everyNonCancelledCategoryHasANonEmptyMessage() throws {
        let route = try route()
        let categories: [MobilePairingFailureCategory] = [
            .offline,
            .hostUnreachable(host: "h", port: 1),
            .listenerNotRunning(host: "h", port: 1),
            .localNetworkBlocked,
            .dnsFailed(host: "h", port: 1),
            .handshakeTimedOut(host: "h", port: 1),
            .connectionDropped(host: "h", port: 1),
            .accountMismatch,
            .emailMismatch(expected: "mac@example.com", actual: "phone@example.com"),
            .authFailed,
            .authEnvironmentMismatch,
            .ticketExpired,
            .invalidCode,
            .unrecognizedVersion,
            .unsupportedRoute,
            .noSupportedRoute,
            .unknown(host: "h", port: 1),
        ]
        for category in categories {
            #expect(!category.message.isEmpty, "category \(category) had an empty message")
        }
        _ = route
    }

    @Test func invalidCodeNoLongerMentionsAPairingCode() {
        // There is no pairing-code secret anymore (the v2 QR carries bare routes
        // and the host authorizes by Stack account). The copy must not imply a
        // wrong "code" was entered.
        let message = MobilePairingFailureCategory.invalidCode.message
        #expect(!message.lowercased().contains("pairing code"))
        #expect(!message.isEmpty)
    }

    @Test func unrecognizedVersionTellsUserToUpdateTheApp() {
        // A real cmux QR from a newer Mac whose grammar this build predates: the
        // user must be told to update, not that the code is invalid.
        let message = MobilePairingFailureCategory.unrecognizedVersion.message
        #expect(message.lowercased().contains("newer version"))
        #expect(MobilePairingFailureCategory.unrecognizedVersion.guidance != nil)
        #expect(MobilePairingFailureCategory.unrecognizedVersion.analyticsReason == "unrecognized_version")
    }

    @Test func missingRouteFallsBackWithoutCrashingOnFormat() {
        // A host/port-format category with no route must fall back to a generic
        // message instead of producing a malformed "%@:%d" string.
        let category = MobilePairingFailureCategory.classify(
            error: CmxNetworkByteTransportError.connectionTimedOut,
            route: nil
        )
        #expect(category == .handshakeTimedOut(host: nil, port: nil))
        #expect(!category.message.isEmpty)
        #expect(!category.message.contains("%@"))
        #expect(!category.message.contains("%d"))
    }
}
