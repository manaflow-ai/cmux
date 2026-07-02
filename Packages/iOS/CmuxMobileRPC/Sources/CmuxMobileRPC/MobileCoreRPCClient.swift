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
    private let ticketState: MobileCoreRPCTicketState
    private let allowsStackAuthFallback: Bool
    // `internal` (not `private`) so `@testable import` can observe session
    // queue state from tests, instead of exposing a debug hook in production.
    let session: MobileCoreRPCSession
    private let stackTokenGate: RPCStackTokenGate
    private let stackTokenForceRefreshGate: RPCStackTokenGate
    // `internal` so `@testable import` can observe redemption sharing without
    // a production-only debug hook.
    let ticketRedemptionGate: MobileCoreRPCTicketRedemptionGate

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
        self.ticketState = MobileCoreRPCTicketState(ticket: ticket)
        self.allowsStackAuthFallback = allowsStackAuthFallback
        self.stackTokenGate = stackTokenGate
            ?? RPCStackTokenGate(timedOutResetNanoseconds: stackTokenGateResetNanoseconds)
        self.stackTokenForceRefreshGate = stackTokenForceRefreshGate
            ?? RPCStackTokenGate(timedOutResetNanoseconds: stackTokenGateResetNanoseconds)
        self.ticketRedemptionGate = MobileCoreRPCTicketRedemptionGate(
            timedOutResetNanoseconds: stackTokenGateResetNanoseconds
        )
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

    /// The effective attach ticket after any ticket-reference redemption.
    ///
    /// Before the first authorized request this is the scanned/persisted ticket.
    /// After a compact QR ticket reference is redeemed, it includes the
    /// authenticated attach token and host-reported ticket context.
    public func currentTicket() async -> CmxAttachTicket {
        await ticketState.current()
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
        let requestNeedsAuth = Self.requestRequiresAuth(request)
        let ticket = try await ticketForRequest(request, deadline: deadline)
        let requestIsCoveredByAttachTicket = !Self.requestNeedsStackAuthFallback(request, ticket: ticket)
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
            if !ticket.isExpired(at: runtime.now()) {
                auth["attach_token"] = attachToken
            } else if !allowsStackAuthFallback || !MobileShellRouteAuthPolicy.routeAllowsStackAuth(route) {
                throw MobileShellConnectionError.attachTicketExpired
            }
        }
        // The host treats Stack auth as the SOLE authorization gate: EVERY
        // authorized request must carry the owner's stack_access_token, even when
        // an attach_token is also present. The attach ticket is route-discovery
        // and workspace-selection only and never authorizes on its own, so a
        // request that ships attach_token-only (e.g. ticket-covered workspace.list)
        // is rejected host-side with `missingStackTokens`. Always present the
        // Stack token for authorized requests; attach_token rides along as
        // supplementary route/workspace context.
        let shouldSendStackAuth = requestNeedsAuth
        if shouldSendStackAuth {
            guard allowsStackAuthFallback,
                  MobileShellRouteAuthPolicy.routeAllowsStackAuth(route) else {
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
           allowsStackAuthFallback,
           MobileShellRouteAuthPolicy.routeAllowsStackAuth(route),
           let stackAccessToken = try await stackAccessTokenForStatus(deadline: deadline) {
            auth["stack_access_token"] = stackAccessToken
        }
        if !auth.isEmpty {
            request["auth"] = auth
        }
        return try JSONSerialization.data(withJSONObject: request)
    }

    private func ticketForRequest(_ request: [String: Any], deadline: RPCRequestDeadline) async throws -> CmxAttachTicket {
        let current = await ticketState.current()
        guard Self.requestRequiresAuth(request),
              ticketReferenceRequiringRedemption(in: current) != nil else {
            return current
        }
        return try await ticketRedemptionGate.ticket(
            timeoutNanoseconds: try deadline.remainingNanoseconds()
        ) { [self] in
            let latest = await ticketState.current()
            guard let ticketRef = ticketReferenceRequiringRedemption(in: latest) else {
                return latest
            }
            let redeemed = try await redeemAttachTicket(
                ticketRef: ticketRef,
                baseTicket: latest,
                deadline: deadline
            )
            await ticketState.replace(with: redeemed)
            return redeemed
        }
    }

    private func redeemAttachTicket(
        ticketRef: String,
        baseTicket: CmxAttachTicket,
        deadline: RPCRequestDeadline
    ) async throws -> CmxAttachTicket {
        guard allowsStackAuthFallback,
              MobileShellRouteAuthPolicy.routeAllowsStackAuth(route) else {
            throw MobileShellConnectionError.insecureManualRoute
        }
        let (id, request) = try Self.requestWithGuaranteedID(
            Self.requestData(
                method: "mobile.attach_ticket.redeem",
                params: ["ticket_ref": ticketRef]
            )
        )
        let authenticated = try await requestDataWithStackAuthOnly(request, deadline: deadline)
        let responseData = try await session.send(
            payload: authenticated,
            requestID: id,
            deadlineUptimeNanoseconds: deadline.uptimeNanoseconds
        )
        let response = try MobileAttachTicketRedeemResponse(decoding: responseData)
        guard response.ticket.ticketRef?.trimmingCharacters(in: .whitespacesAndNewlines) == ticketRef else {
            throw MobileShellConnectionError.invalidResponse
        }
        return try redeemedTicket(
            response.ticket,
            ticketRef: ticketRef,
            constrainedTo: baseTicket
        )
    }

    private func requestDataWithStackAuthOnly(_ requestData: Data, deadline: RPCRequestDeadline) async throws -> Data {
        guard var request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return requestData
        }
        let accessToken: String
        do {
            accessToken = try await stackAccessToken(deadline: deadline)
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
        request["auth"] = [
            "stack_access_token": accessToken
        ]
        return try JSONSerialization.data(withJSONObject: request)
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
        guard requestRequiresAuth(request) else {
            return false
        }
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = request["params"] as? [String: Any] ?? [:]
        let workspaceSelection = stringParamSelection(params, keys: ["workspace_id"])
        let terminalSelection = stringParamSelection(params, keys: ["surface_id", "terminal_id", "tab_id"])
        let ticketCoverage = MobileCoreRPCAttachTicketCoverage()
        if workspaceSelection.hasConflict ||
            terminalSelection.hasConflict ||
            ticketCoverage.containsIgnoredAliasParameters(params) {
            return true
        }

        switch method {
        case "mobile.workspace.list", "workspace.list":
            return false
        case "workspace.create":
            return false
        case "workspace.action", "workspace.close":
            return !ticketCoverage.ticketCoversWorkspaceRequest(
                ticket: ticket,
                workspaceSelection: workspaceSelection.value
            )
        case "mobile.terminal.create", "terminal.create":
            return false
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.paste", "terminal.paste",
             "mobile.terminal.paste_image", "terminal.paste_image",
             "mobile.terminal.replay", "terminal.replay",
             "mobile.terminal.viewport", "terminal.viewport":
            return !ticketCoverage.ticketCoversTerminalRequest(
                ticket: ticket,
                workspaceSelection: workspaceSelection.value,
                terminalSelection: terminalSelection.value
            )
        case "mobile.events.subscribe", "mobile.events.unsubscribe":
            return false
        default:
            return true
        }
    }

    private static func requestRequiresAuth(_ request: [String: Any]) -> Bool {
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the unauthenticated host probe is exempt. attach_ticket.create has no
        // attach token yet (it mints the ticket), so requiring auth routes it through
        // the Stack Auth account token: a ticket can only be created by a signed-in user.
        return method != "mobile.host.status"
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
