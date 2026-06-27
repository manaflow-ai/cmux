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
    public init(
        runtime: any MobileSyncRuntime,
        route: CmxAttachRoute,
        ticket: CmxAttachTicket,
        allowsStackAuthFallback: Bool = false,
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
                allowAuthRetry: true,
                forceStackAuthFallback: false
            )
        } catch let error as MobileCoreRPCAttachTokenAuthorizationFailure {
            guard shouldRetryAttachTokenAuthorizationFailureWithStackAuth(error.underlying) else {
                throw error.underlying
            }
            do {
                return try await sendAuthenticatedRequest(
                    requestData,
                    deadline: deadline,
                    allowAuthRetry: false,
                    forceStackAuthFallback: true
                )
            } catch let stackError as MobileShellConnectionError {
                guard case .authorizationFailed = stackError else { throw stackError }
                try await forceRefreshStackTokenForRetry(deadline: deadline)
                return try await sendAuthenticatedRequest(
                    requestData,
                    deadline: deadline,
                    allowAuthRetry: false,
                    forceStackAuthFallback: true
                )
            }
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
                allowAuthRetry: false,
                forceStackAuthFallback: false
            )
        }
    }

    private func shouldRetryAttachTokenAuthorizationFailureWithStackAuth(
        _ error: MobileShellConnectionError
    ) -> Bool {
        guard case let .authorizationFailed(message) = error else {
            return false
        }
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mentionsAttachToken = normalizedMessage.contains("attach token")
            || normalizedMessage.contains("attach-token")
            || normalizedMessage.contains("attach_ticket")
            || normalizedMessage.contains("invalid_attach_token")
        guard !mentionsAttachToken else {
            return false
        }
        return normalizedMessage == "unauthorized"
            || normalizedMessage == "authorization failed"
            || (normalizedMessage.contains("mobile sync") && normalizedMessage.contains("auth"))
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
        allowAuthRetry: Bool,
        forceStackAuthFallback: Bool
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
            deadline: deadline,
            forceStackAuthFallback: forceStackAuthFallback
        )
        try Task.checkCancellation()
        do {
            return try await session.send(
                payload: authenticated.data,
                requestID: id,
                deadlineUptimeNanoseconds: deadline.uptimeNanoseconds
            )
        } catch let error as MobileShellConnectionError {
            if authenticated.usedAttachToken,
               case .authorizationFailed = error {
                throw MobileCoreRPCAttachTokenAuthorizationFailure(underlying: error)
            }
            throw error
        }
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

    private func requestDataWithAuth(
        _ requestData: Data,
        deadline: RPCRequestDeadline,
        forceStackAuthFallback: Bool
    ) async throws -> MobileCoreRPCAuthenticatedRequest {
        guard var request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return MobileCoreRPCAuthenticatedRequest(data: requestData, usedAttachToken: false)
        }
        let requestMethod = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestNeedsAuth = requestMethod != "mobile.host.status"
        let requestIsCoveredByAttachTicket = !forceStackAuthFallback && !Self.requestNeedsStackAuthFallback(request, ticket: ticket)
        let routeAllowsBearerAuth = MobileShellRouteAuthPolicy.routeAllowsStackAuth(route)
        let routeAllowsStackAuthFallback = allowsStackAuthFallback && routeAllowsBearerAuth
        var auth: [String: Any] = [:]
        let attachToken = ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachToken = attachToken?.isEmpty == false
        if let attachToken,
           requestNeedsAuth,
           hasAttachToken,
           requestIsCoveredByAttachTicket {
            // Expiry is enforced only here, where the RPC-minted attach token
            // is actually used. QR-decoded tickets carry no token (and no
            // expiry), so they never reach this branch.
            if ticket.isExpired(at: runtime.now()) {
                if !routeAllowsStackAuthFallback {
                    throw MobileShellConnectionError.attachTicketExpired
                }
            } else if routeAllowsBearerAuth {
                auth["attach_token"] = attachToken
            }
        }
        // A non-expired attach token is the local authorization credential for
        // ticket-covered attach/reconnect/session-restore requests. Stack auth is
        // the fallback for tokenless pairing flows, requests outside the ticket's
        // scope, and trusted routes whose attach token has expired locally.
        let requestHasAttachAuth = auth["attach_token"] != nil
        let shouldSendStackAuth = requestNeedsAuth && (forceStackAuthFallback || !requestHasAttachAuth)
        if shouldSendStackAuth {
            guard routeAllowsStackAuthFallback else {
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
        if !requestNeedsAuth,
           isHostStatusRequest(request),
           routeAllowsStackAuthFallback,
           let stackAccessToken = try await stackAccessTokenForStatus(deadline: deadline) {
            auth["stack_access_token"] = stackAccessToken
        }
        if !auth.isEmpty {
            request["auth"] = auth
        }
        return try MobileCoreRPCAuthenticatedRequest(
            data: JSONSerialization.data(withJSONObject: request),
            usedAttachToken: requestHasAttachAuth
        )
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

    private static func requestNeedsStackAuthFallback(_ request: [String: Any], ticket: CmxAttachTicket) -> Bool {
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the unauthenticated host probe is exempt. attach_ticket.create has no
        // attach token yet (it mints the ticket), so requiring auth routes it through
        // the Stack Auth account token: a ticket can only be created by a signed-in user.
        guard method != "mobile.host.status" else {
            return false
        }
        let params = request["params"] as? [String: Any] ?? [:]
        let stringParamSelection: ([String]) -> StringParamSelection = { keys in
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
        let workspaceSelection = stringParamSelection(["workspace_id"])
        let terminalSelection = stringParamSelection(["surface_id", "terminal_id", "tab_id"])
        let hasMacAccountBinding =
            ticket.macUserID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
            ticket.macUserEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasTerminalScope = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let ticketCoverage = MobileCoreRPCAttachTicketCoverage()
        if workspaceSelection.hasConflict ||
            terminalSelection.hasConflict ||
            ticketCoverage.containsIgnoredAliasParameters(params) {
            return true
        }

        switch method {
        case "mobile.workspace.list", "workspace.list":
            if workspaceSelection.value == nil {
                return terminalSelection.value != nil || !hasMacAccountBinding || hasTerminalScope
            }
            return !ticketCoverage.ticketCoversTerminalRequest(
                ticket: ticket,
                workspaceSelection: workspaceSelection.value,
                terminalSelection: terminalSelection.value
            )
        case "workspace.create":
            return !hasMacAccountBinding || !ticketCoverage.ticketCoversWorkspaceCreateRequest(ticket: ticket)
        case "workspace.group.collapse", "workspace.group.expand":
            return !ticketCoverage.ticketCoversMacWideRequest(ticket: ticket)
        case "workspace.action", "workspace.close":
            return !ticketCoverage.ticketCoversWorkspaceRequest(
                ticket: ticket,
                workspaceSelection: workspaceSelection.value
            )
        case "mobile.terminal.create", "terminal.create":
            return !ticketCoverage.ticketCoversTerminalCreateRequest(
                ticket: ticket,
                workspaceSelection: workspaceSelection.value,
                terminalSelection: terminalSelection.value
            )
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
            return !ticketCoverage.ticketCoversMacWideRequest(ticket: ticket)
        default:
            return true
        }
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
