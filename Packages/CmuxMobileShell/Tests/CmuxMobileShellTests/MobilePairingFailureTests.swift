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

    @Test func insecureManualRouteIsUnsupportedRoute() {
        let category = MobilePairingFailureCategory.classify(
            error: MobileShellConnectionError.insecureManualRoute,
            route: nil
        )
        #expect(category == .unsupportedRoute)
        #expect(category.analyticsReason == "unsupported_route")
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
        for category in Self.allNonCancelledCategories {
            #expect(!category.message.isEmpty, "category \(category) had an empty message")
        }
        _ = route
    }

    @Test func everyCategoryHasADistinctAnalyticsReason() {
        let reasons = Self.allNonCancelledCategories.map(\.analyticsReason) + [
            MobilePairingFailureCategory.cancelled.analyticsReason
        ]
        #expect(Set(reasons).count == reasons.count, "analytics reasons must stay distinct: \(reasons)")
    }

    /// One of every case (cancelled excluded where noted) so the message and
    /// analytics matrix tests cannot silently skip a newly added category.
    private static let allNonCancelledCategories: [MobilePairingFailureCategory] = [
        .offline,
        .hostUnreachable(host: "h", port: 1),
        .listenerNotRunning(host: "h", port: 1),
        .localNetworkBlocked,
        .dnsFailed(host: "h", port: 1),
        .handshakeTimedOut(host: "h", port: 1),
        .connectionDropped(host: "h", port: 1),
        .accountMismatch,
        .authFailed,
        .ticketExpired,
        .invalidCode,
        .codeFromNewerApp,
        .codeFromOlderMac,
        .tailscaleOff(host: "h", port: 1),
        .alreadyPaired(macName: "Test Mac"),
        .pairedButNotSaved,
        .unsupportedRoute,
        .noSupportedRoute,
        .unknown(host: "h", port: 1),
    ]

    // MARK: - Decode-error classification (the validation phase of the QR journey)

    @Test func newerPairPayloadVersionMeansUpdateThisApp() {
        let category = MobilePairingFailureCategory.classify(
            decodeError: MobileSyncPairingPayloadError.unsupportedVersion(2)
        )
        #expect(category == .codeFromNewerApp)
        #expect(category.analyticsReason == "code_newer_version")
        #expect(category.message.lowercased().contains("update"))
        #expect(category.guidance != nil)
    }

    @Test func olderPairPayloadVersionMeansUpdateTheMac() {
        let category = MobilePairingFailureCategory.classify(
            decodeError: MobileSyncPairingPayloadError.unsupportedVersion(0)
        )
        #expect(category == .codeFromOlderMac)
        #expect(category.analyticsReason == "code_older_version")
        #expect(category.message.lowercased().contains("update"))
        #expect(category.guidance != nil)
    }

    @Test func unsupportedPayloadFormatMeansUpdateThisApp() {
        // The compact short-key QR grammar from a newer Mac
        // (https://github.com/manaflow-ai/cmux/pull/5727): unreadable here, so
        // the only recovery is updating this app, never rescanning.
        let category = MobilePairingFailureCategory.classify(
            decodeError: MobileSyncPairingPayloadError.unsupportedPayloadFormat(2)
        )
        #expect(category == .codeFromNewerApp)
    }

    @Test func newerTicketVersionMeansUpdateThisApp() {
        let category = MobilePairingFailureCategory.classify(
            decodeError: CmxAttachTicketError.unsupportedVersion(3)
        )
        #expect(category == .codeFromNewerApp)
    }

    @Test func expiredDecodeErrorsClassifyAsTicketExpired() {
        #expect(MobilePairingFailureCategory.classify(
            decodeError: MobileSyncPairingPayloadError.expired
        ) == .ticketExpired)
        #expect(MobilePairingFailureCategory.classify(
            decodeError: CmxAttachTicketError.expired
        ) == .ticketExpired)
    }

    @Test func malformedDecodeErrorsClassifyAsInvalidCode() {
        #expect(MobilePairingFailureCategory.classify(
            decodeError: MobileSyncPairingPayloadError.invalidURL
        ) == .invalidCode)
        #expect(MobilePairingFailureCategory.classify(
            decodeError: CmxAttachTicketError.noRoutes
        ) == .invalidCode)
        // Untyped decode failures (raw DecodingError, anything else) still get
        // the actionable refresh-code message.
        struct SomeError: Error {}
        let category = MobilePairingFailureCategory.classify(decodeError: SomeError())
        #expect(category == .invalidCode)
        #expect(!category.message.isEmpty)
    }

    // MARK: - Tailnet-off refinement (the #5722 detector seam)

    @Test func tailnetOffUpgradesUnreachableTailnetIPv4Host() {
        let category = MobilePairingFailureCategory
            .hostUnreachable(host: "100.71.210.41", port: 58_465)
            .refined(tailnetHint: .inactiveOrNotInstalled)
        #expect(category == .tailscaleOff(host: "100.71.210.41", port: 58_465))
        #expect(category.analyticsReason == "tailscale_off")
        #expect(category.message.contains("Tailscale"))
        #expect(category.message.contains("100.71.210.41"))
        #expect(category.guidance != nil)
    }

    @Test func tailnetOffUpgradesDNSFailureOnMagicDNSName() {
        let category = MobilePairingFailureCategory
            .dnsFailed(host: "my-mac.tail.ts.net", port: 58_465)
            .refined(tailnetHint: .inactiveOrNotInstalled)
        #expect(category == .tailscaleOff(host: "my-mac.tail.ts.net", port: 58_465))
    }

    @Test func tailnetOffUpgradesTimeoutOnTailscaleULAHost() {
        let category = MobilePairingFailureCategory
            .handshakeTimedOut(host: "fd7a:115c:a1e0:ab12::1", port: 58_465)
            .refined(tailnetHint: .inactiveOrNotInstalled)
        #expect(category == .tailscaleOff(host: "fd7a:115c:a1e0:ab12::1", port: 58_465))
    }

    @Test func activeOrUnknownTailnetHintRefinesNothing() {
        let unreachable = MobilePairingFailureCategory.hostUnreachable(host: "100.71.210.41", port: 1)
        #expect(unreachable.refined(tailnetHint: .active) == unreachable)
        #expect(unreachable.refined(tailnetHint: .unknown) == unreachable)
    }

    @Test func nonTailnetHostsAreNeverUpgraded() {
        // LAN IP, public DNS name, CGNAT-adjacent but out-of-range IP, no host.
        for host in ["192.168.1.20", "example.com", "100.128.0.1", "100.63.255.255"] {
            let category = MobilePairingFailureCategory.hostUnreachable(host: host, port: 1)
            #expect(category.refined(tailnetHint: .inactiveOrNotInstalled) == category, "host \(host) must not refine")
        }
        let hostless = MobilePairingFailureCategory.hostUnreachable(host: nil, port: nil)
        #expect(hostless.refined(tailnetHint: .inactiveOrNotInstalled) == hostless)
    }

    @Test func nonReachabilityCategoriesAreNeverUpgraded() {
        // Only host-unreachable / dns / timeout can mean "tailnet down"; a
        // refused connection proves the address routed, so it must keep its
        // listener-specific message even with the tailnet off.
        let refused = MobilePairingFailureCategory.listenerNotRunning(host: "100.71.210.41", port: 1)
        #expect(refused.refined(tailnetHint: .inactiveOrNotInstalled) == refused)
        let auth = MobilePairingFailureCategory.accountMismatch
        #expect(auth.refined(tailnetHint: .inactiveOrNotInstalled) == auth)
    }

    // MARK: - Notice categories

    @Test func alreadyPairedNamesTheMacAndNeedsNoGuidance() {
        let named = MobilePairingFailureCategory.alreadyPaired(macName: "Studio")
        #expect(named.message.contains("Studio"))
        #expect(named.guidance == nil)
        #expect(named.analyticsReason == "already_paired")
        #expect(!named.isAuthorizationFailure)

        let unnamed = MobilePairingFailureCategory.alreadyPaired(macName: nil)
        #expect(!unnamed.message.isEmpty)
        #expect(!unnamed.message.contains("%@"))
    }

    @Test func pairedButNotSavedExplainsTheConsequence() {
        let category = MobilePairingFailureCategory.pairedButNotSaved
        #expect(category.analyticsReason == "paired_store_failed")
        #expect(category.message.lowercased().contains("save"))
        #expect(!category.isAuthorizationFailure)
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
