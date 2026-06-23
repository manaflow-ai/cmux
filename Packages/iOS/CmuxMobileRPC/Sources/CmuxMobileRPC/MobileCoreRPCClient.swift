public import CMUXMobileCore
internal import CmuxMobileShellModel
internal import CmuxMobileSupport
public import Foundation
internal import os

/// A multiplexed RPC client over a single persistent transport to a paired Mac.
///
/// All stored properties are immutable `let`s of `Sendable` types (the session
/// is an actor), so this is genuinely `Sendable` without opting out of checking.
public final class MobileCoreRPCClient: MobileSyncing, Sendable {
    private let runtime: any MobileSyncRuntime
    private let route: CmxAttachRoute
    private let ticket: CmxAttachTicket
    private let allowsStackAuthFallback: Bool
    private let trustedNetworkAuthConfirmed: Bool
    // `internal` (not `private`) so `@testable import` can observe session
    // queue state from tests, instead of exposing a debug hook in production.
    let session: MobileCoreRPCSession
    private let stackTokenGate: RPCStackTokenGate
    private let stackTokenForceRefreshGate: RPCStackTokenGate

    /// Create a client bound to one route + attach ticket.
    /// - Parameters:
    ///   - runtime: The DI runtime supplying transport factory, token provider, timeouts, clock.
    ///   - route: The attach route this client connects over.
    ///   - ticket: The attach ticket authorizing requests.
    ///   - allowsStackAuthFallback: When `true`, falls back to a Stack Auth token
    ///     on routes that allow it once the attach ticket no longer covers a request.
    ///   - trustedNetworkAuthConfirmed: Retained for call-site compatibility.
    ///     Confirmation permits only the tokenless `mobile.attach_ticket.create`
    ///     request on plaintext `.trustedNetwork` routes. It never permits Stack
    ///     auth on those routes.
    public init(
        runtime: any MobileSyncRuntime,
        route: CmxAttachRoute,
        ticket: CmxAttachTicket,
        allowsStackAuthFallback: Bool = false,
        trustedNetworkAuthConfirmed: Bool = false,
        connectAttemptRegistry: MobileRPCConnectAttemptRegistry = MobileRPCConnectAttemptRegistry(),
        stackTokenGate: RPCStackTokenGate? = nil,
        stackTokenForceRefreshGate: RPCStackTokenGate? = nil,
        abandonedConnectCleanupTimeoutNanoseconds: UInt64 = 1_000_000_000,
        lateAbandonedConnectCloseTimeoutNanoseconds: UInt64 = 5_000_000_000,
        stackTokenGateResetNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.runtime = runtime
        self.route = route
        self.ticket = ticket
        self.allowsStackAuthFallback = allowsStackAuthFallback
        self.trustedNetworkAuthConfirmed = trustedNetworkAuthConfirmed
        self.stackTokenGate = stackTokenGate
            ?? RPCStackTokenGate(timedOutResetNanoseconds: stackTokenGateResetNanoseconds)
        self.stackTokenForceRefreshGate = stackTokenForceRefreshGate
            ?? RPCStackTokenGate(timedOutResetNanoseconds: stackTokenGateResetNanoseconds)
        self.session = MobileCoreRPCSession(
            connectAttemptKey: route.mobileRPCConnectAttemptKey,
            connectAttemptRegistry: connectAttemptRegistry,
            abandonedConnectCleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
            lateAbandonedConnectCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds,
            makeTransport: { [route, runtime] in
                try runtime.transportFactory.makeTransport(for: route)
            }
        )
    }

    /// Tear down the persistent transport (called when the client is
    /// replaced or the user signs out).
    public func disconnect() async {
        await session.tearDown(error: .connectionClosed)
    }

    /// Subscribe to server-pushed events. Returns a stream of envelopes
    /// matching any of the requested topics. Cancel by terminating iteration.
    public func subscribe(to topics: Set<String>) async -> AsyncStream<MobileEventEnvelope> {
        await session.addEventListener(topics: topics).stream
    }

    /// Build a JSON-RPC request frame with the given method and params.
    /// - Parameters:
    ///   - method: The RPC method name.
    ///   - params: The request parameters.
    ///   - id: The request id (defaults to a fresh UUID).
    /// - Returns: The encoded request data.
    /// - Throws: A serialization error if the params are not JSON-encodable.
    public static func requestData(
        method: String,
        params: [String: Any] = [:],
        id: String = UUID().uuidString
    ) throws -> Data {
        let request: [String: Any] = [
            "id": id,
            "method": method,
            "params": params,
        ]
        return try JSONSerialization.data(withJSONObject: request)
    }

    /// Sends one JSON-RPC request over the paired Mac connection.
    ///
    /// The optional timeout is a hard end-to-end deadline for auth augmentation,
    /// connection setup, and response wait, not a per-subphase timeout.
    public func sendRequest(_ requestData: Data, timeoutNanoseconds: UInt64? = nil) async throws -> Data {
        let deadline = RPCRequestDeadline(
            timeoutNanoseconds: timeoutNanoseconds ?? runtime.rpcRequestTimeoutNanoseconds
        )
        do {
            return try await sendAuthenticatedRequest(
                requestData,
                deadline: deadline,
                allowAuthRetry: true
            )
        } catch let error as MobileShellConnectionError {
            // The host rejected this request on Stack-auth grounds. Before
            // surfacing it (which drives the re-auth prompt), force exactly one
            // fresh-token mint and retry once: the persisted access token is
            // commonly just stale past its ~1h TTL while the refresh token is
            // still valid, and a normal provider call would hand back the same
            // stale token. An `account_mismatch` rejection is deliberately NOT
            // retried here — it means the Mac is signed in to a different
            // account, so retrying with a fresh token of THIS account cannot
            // help and would only weaken the same-account gate; it surfaces as
            // `.rpcError("account_mismatch", _)`, not `.authorizationFailed`.
            guard case .authorizationFailed = error else { throw error }
            try await forceRefreshStackTokenForRetry(deadline: deadline)
            // Re-run with retry disabled so a fresh token that is still rejected
            // surfaces as a definitive auth failure instead of looping.
            return try await sendAuthenticatedRequest(
                requestData,
                deadline: deadline,
                allowAuthRetry: false
            )
        }
    }

    /// Force a single Stack token refresh ahead of a retry.
    ///
    /// The force-refresher closure maps a transient refresh failure (session
    /// intact) to `.connectionClosed` so a network blip stays retryable and does
    /// not trip the re-auth prompt; a definitive failure surfaces as
    /// `.authorizationFailed` to drive re-auth.
    private func forceRefreshStackTokenForRetry(deadline: RPCRequestDeadline) async throws {
        do {
            _ = try await stackTokenForceRefreshGate.token(
                timeoutNanoseconds: try deadline.remainingNanoseconds()
            ) { [runtime] in
                try await runtime.stackAccessTokenForceRefresher()
            }
        } catch let error as MobileShellConnectionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MobileShellConnectionError.authorizationFailed(
                L10n.string(
                    "mobile.pairing.stackAuthTokenUnavailable",
                    defaultValue: "Sign in on your computer with the same account, then try again."
                )
            )
        }
    }

    private func sendAuthenticatedRequest(
        _ requestData: Data,
        deadline: RPCRequestDeadline,
        allowAuthRetry: Bool
    ) async throws -> Data {
        // Multiplexed over a persistent transport: each request gets a unique
        // id, the session's reader task routes the response back here. No
        // connect/close per RPC, no head-of-line blocking between calls.
        // `forceID` mints a brand-new id on the retry pass so it never collides
        // with the first attempt's already-resolved pending continuation.
        let (id, augmented) = try Self.requestWithGuaranteedID(
            requestData,
            forceID: !allowAuthRetry
        )
        let authenticated = try await requestDataWithAuth(
            augmented,
            deadline: deadline
        )
        try Task.checkCancellation()
        return try await session.send(
            payload: authenticated,
            requestID: id,
            deadlineUptimeNanoseconds: deadline.uptimeNanoseconds
        )
    }

    private static func requestWithGuaranteedID(
        _ requestData: Data,
        forceID: Bool = false
    ) throws -> (String, Data) {
        guard var dict = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            throw MobileShellConnectionError.invalidResponse
        }
        let id: String
        if !forceID, let existing = dict["id"] as? String, !existing.isEmpty {
            id = existing
        } else {
            id = UUID().uuidString
            dict["id"] = id
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return (id, data)
    }

    private func requestDataWithAuth(_ requestData: Data, deadline: RPCRequestDeadline) async throws -> Data {
        guard var request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return requestData
        }
        let requestNeedsAuth = requestRequiresAuth(request)
        let requestIsCoveredByAttachTicket = !requestNeedsStackAuthFallback(request, ticket: ticket)
        var auth: [String: Any] = [:]
        let attachToken = ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachToken = attachToken?.isEmpty == false
        let statusRequest = isHostStatusRequest(request)
        if let attachToken,
           hasAttachToken,
           (requestNeedsAuth && requestIsCoveredByAttachTicket || statusRequest) {
            // Expiry is enforced only here, where the RPC-minted attach token
            // is actually used. QR-decoded tickets carry no token (and no
            // expiry), so they never reach this branch.
            if !ticket.isExpired(at: runtime.now()) {
                auth["attach_token"] = attachToken
            } else if !allowsStackAuthFallback || !routeAllowsStackAuth {
                throw MobileShellConnectionError.attachTicketExpired
            }
        }
        // Encrypted/loopback routes use the Stack account token. Plain
        // trusted-network host/port routes must never carry that account bearer;
        // they can proceed only when a Mac-minted attach token covers the request.
        let shouldSendStackAuth = requestNeedsAuth && routeAllowsStackAuth
        if shouldSendStackAuth {
            guard allowsStackAuthFallback,
                  routeAllowsStackAuth else {
                throw MobileShellConnectionError.insecureManualRoute
            }
            do {
                auth["stack_access_token"] = try await stackAccessToken(deadline: deadline)
            } catch let error as MobileShellConnectionError {
                // The provider already classified the failure: a transient
                // token-fetch failure (offline / refresh server hiccup, session
                // still intact) maps to `.connectionClosed` so the connection
                // survives a network blip past the ~1h access-token TTL without a
                // manual re-sign-in; only a definitive failure surfaces as
                // `.authorizationFailed` to route to the re-auth prompt. Mapping
                // everything to `.authorizationFailed` here is what made retry
                // fail permanently.
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MobileShellConnectionError.authorizationFailed(
                    L10n.string(
                        "mobile.pairing.stackAuthTokenUnavailable",
                        defaultValue: "Sign in on your computer with the same account, then try again."
                    )
                )
            }
        }
        if requestNeedsAuth,
           !routeAllowsStackAuth,
           auth["attach_token"] == nil {
            if trustedNetworkAuthConfirmed,
               isTrustedNetworkRoute,
               isAttachTicketCreateRequest(request),
               requestHasTrustedNetworkPairingSecret(request) {
                return try JSONSerialization.data(withJSONObject: request)
            }
            throw MobileShellConnectionError.insecureManualRoute
        }
        if !requestNeedsAuth,
           statusRequest,
           allowsStackAuthFallback,
           routeAllowsStackAuth,
           let stackAccessToken = try await stackAccessTokenForStatus(deadline: deadline) {
            auth["stack_access_token"] = stackAccessToken
        }
        if !auth.isEmpty {
            request["auth"] = auth
        }
        return try JSONSerialization.data(withJSONObject: request)
    }

    private var routeAllowsStackAuth: Bool {
        MobileShellRouteAuthPolicy.routeAllowsStackAuth(route)
    }

    private var isTrustedNetworkRoute: Bool {
        if case (.trustedNetwork, .hostPort) = (route.kind, route.endpoint) {
            return true
        }
        return false
    }

    private func stackAccessTokenForStatus(deadline: RPCRequestDeadline) async throws -> String? {
        let task = Task<String?, any Error> { [runtime] in
            await runtime.stackAccessTokenForStatusProvider()
        }
        do {
            return try await RPCTaskTimeout().value(
                task,
                timeoutNanoseconds: try deadline.remainingNanoseconds()
            )
        } catch {
            task.cancel()
            throw error
        }
    }

    private func stackAccessToken(deadline: RPCRequestDeadline) async throws -> String {
        try await stackTokenGate.token(timeoutNanoseconds: try deadline.remainingNanoseconds()) { [runtime] in
            try await runtime.stackAccessTokenProvider()
        }
    }

    private func isAttachTicketCreateRequest(_ request: [String: Any]) -> Bool {
        (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "mobile.attach_ticket.create"
    }

    private func requestHasTrustedNetworkPairingSecret(_ request: [String: Any]) -> Bool {
        guard let params = request["params"] as? [String: Any],
              let secret = params["trusted_network_pairing_secret"] as? String else {
            return false
        }
        return !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func requestRequiresAuth(_ request: [String: Any]) -> Bool {
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the host probe is generally exempt. `mobile.attach_ticket.create`
        // has no attach token yet, so encrypted/loopback routes use Stack auth; a
        // confirmed trusted-network route sends that one request tokenless and relies
        // on the Mac's short pairing-window mint grant.
        return method != "mobile.host.status"
    }

    private func requestNeedsStackAuthFallback(_ request: [String: Any], ticket: CmxAttachTicket) -> Bool {
        guard requestRequiresAuth(request) else {
            return false
        }
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = request["params"] as? [String: Any] ?? [:]
        let workspaceSelection = Self.stringParamSelection(params, keys: ["workspace_id"])
        let terminalSelection = Self.stringParamSelection(params, keys: ["surface_id", "terminal_id", "tab_id"])
        let ticketCoverage = MobileCoreRPCAttachTicketCoverage()
        if workspaceSelection.hasConflict ||
            terminalSelection.hasConflict ||
            ticketCoverage.containsIgnoredAliasParameters(params) {
            return true
        }

        switch method {
        case "mobile.workspace.list", "workspace.list":
            return !ticketCoverage.ticketCoversMacScopedRequest(ticket: ticket)
        case "workspace.create":
            return false
        case "workspace.action", "workspace.close":
            return !ticketCoverage.ticketCoversWorkspaceRequest(
                ticket: ticket,
                workspaceSelection: workspaceSelection.value
            )
        case "workspace.group.collapse", "workspace.group.expand":
            return !ticketCoverage.ticketCoversMacScopedRequest(ticket: ticket)
        case "mobile.terminal.create", "terminal.create":
            return false
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.paste", "terminal.paste",
             "mobile.terminal.paste_image", "terminal.paste_image",
             "mobile.terminal.replay", "terminal.replay",
             "mobile.terminal.viewport", "terminal.viewport",
             "mobile.terminal.scroll", "terminal.scroll",
             "mobile.terminal.mouse", "terminal.mouse":
            return !ticketCoverage.ticketCoversTerminalRequest(
                ticket: ticket,
                workspaceSelection: workspaceSelection.value,
                terminalSelection: terminalSelection.value
            )
        case "mobile.events.subscribe", "mobile.events.unsubscribe":
            return !ticketCoverage.ticketCoversMacScopedRequest(ticket: ticket)
        case "notification.dismiss", "notification.reconcile":
            return !ticketCoverage.ticketCoversMacScopedRequest(ticket: ticket)
        case "mobile.chat.sessions":
            return !ticketCoverage.ticketCoversWorkspaceRequest(
                ticket: ticket,
                workspaceSelection: workspaceSelection.value
            )
        case let method where method?.hasPrefix("mobile.chat.") == true:
            return !ticketCoverage.ticketCoversMacScopedRequest(ticket: ticket)
        default:
            return true
        }
    }

    private static func stringParamSelection(
        _ params: [String: Any],
        keys: [String]
    ) -> StringParamSelection {
        var selected: String?
        for key in keys {
            if let value = params[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if let selected, selected != trimmed {
                        return StringParamSelection(value: selected, hasConflict: true)
                    }
                    selected = selected ?? trimmed
                }
            }
        }
        return StringParamSelection(value: selected, hasConflict: false)
    }

    private struct StringParamSelection {
        let value: String?
        let hasConflict: Bool
    }

}

private extension MobileCoreRPCClient {
    /// Whether `request` is the unauthenticated `mobile.host.status` probe, the
    /// one verb whose reply may carry host identity for verified callers.
    func isHostStatusRequest(_ request: [String: Any]) -> Bool {
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return method == "mobile.host.status"
    }
}

private extension CmxAttachRoute {
    var mobileRPCConnectAttemptKey: String {
        "\(kind.rawValue)|\(id)|\(endpoint.logDescription)"
    }
}
