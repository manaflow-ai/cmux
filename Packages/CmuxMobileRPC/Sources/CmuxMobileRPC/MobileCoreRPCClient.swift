public import CMUXMobileCore
internal import CmuxMobileShellModel
internal import CmuxMobileSupport
public import Foundation

/// A multiplexed RPC client over a single persistent transport to a paired Mac.
///
/// All stored properties are immutable `let`s of `Sendable` types (the session
/// is an actor), so this is genuinely `Sendable` without opting out of checking.
public final class MobileCoreRPCClient: MobileSyncing, Sendable {
    private let runtime: any MobileSyncRuntime
    private let route: CmxAttachRoute
    private let ticket: CmxAttachTicket
    private let allowsStackAuthFallback: Bool
    private let session: MobileCoreRPCSession

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
        allowsStackAuthFallback: Bool = false
    ) {
        self.runtime = runtime
        self.route = route
        self.ticket = ticket
        self.allowsStackAuthFallback = allowsStackAuthFallback
        self.session = MobileCoreRPCSession(
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

    public func sendRequest(_ requestData: Data, timeoutNanoseconds: UInt64? = nil) async throws -> Data {
        do {
            return try await sendAuthenticatedRequest(
                requestData,
                timeoutNanoseconds: timeoutNanoseconds,
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
            try await forceRefreshStackTokenForRetry()
            // Re-run with retry disabled so a fresh token that is still rejected
            // surfaces as a definitive auth failure instead of looping.
            return try await sendAuthenticatedRequest(
                requestData,
                timeoutNanoseconds: timeoutNanoseconds,
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
    private func forceRefreshStackTokenForRetry() async throws {
        do {
            _ = try await runtime.stackAccessTokenForceRefresher()
        } catch let error as MobileShellConnectionError {
            throw error
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
        timeoutNanoseconds: UInt64?,
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
        let authenticated = try await requestDataWithAuth(augmented)
        return try await Self.withRequestTimeout(
            timeoutNanoseconds: timeoutNanoseconds ?? runtime.rpcRequestTimeoutNanoseconds
        ) {
            try await self.session.send(payload: authenticated, requestID: id)
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

    private func requestDataWithAuth(_ requestData: Data) async throws -> Data {
        guard var request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return requestData
        }
        let requestNeedsAuth = Self.requestRequiresAuth(request)
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
                auth["stack_access_token"] = try await runtime.stackAccessTokenProvider()
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
            } catch {
                throw MobileShellConnectionError.authorizationFailed(
                    L10n.string(
                        "mobile.pairing.stackAuthTokenUnavailable",
                        defaultValue: "Sign in on your computer with the same account, then try again."
                    )
                )
            }
        }
        // The status probe is deliberately unauthenticated (it must answer
        // before the phone has anything to present), but the host reports its
        // identity (`mac_device_id`, `mac_display_name`) only to a verified
        // same-account caller, so attach the Stack token opportunistically
        // when policy allows sending it on this route. Never fail the probe
        // over a missing token: reachability and capabilities don't need one,
        // and a QR-pairing connect (where the identity matters) is always
        // signed in, so the token is present there.
        if !requestNeedsAuth,
           Self.isHostStatusRequest(request),
           allowsStackAuthFallback,
           MobileShellRouteAuthPolicy.routeAllowsStackAuth(route),
           let stackAccessToken = try? await runtime.stackAccessTokenProvider() {
            auth["stack_access_token"] = stackAccessToken
        }
        if !auth.isEmpty {
            request["auth"] = auth
        }
        return try JSONSerialization.data(withJSONObject: request)
    }

    private static func isHostStatusRequest(_ request: [String: Any]) -> Bool {
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return method == "mobile.host.status"
    }

    private static func requestNeedsStackAuthFallback(_ request: [String: Any], ticket: CmxAttachTicket) -> Bool {
        guard requestRequiresAuth(request) else {
            return false
        }
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = request["params"] as? [String: Any] ?? [:]
        let workspaceSelection = stringParamSelection(params, keys: ["workspace_id"])
        let terminalSelection = stringParamSelection(params, keys: ["surface_id", "terminal_id", "tab_id"])
        if workspaceSelection.hasConflict ||
            terminalSelection.hasConflict ||
            containsIgnoredAliasParameters(params) {
            return true
        }

        switch method {
        case "mobile.workspace.list", "workspace.list":
            return false
        case "workspace.create":
            return false
        case "mobile.terminal.create", "terminal.create":
            return false
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.paste_image", "terminal.paste_image",
             "mobile.terminal.replay", "terminal.replay",
             "mobile.terminal.viewport", "terminal.viewport":
            return !ticketCoversTerminalRequest(
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

    private static func ticketCoversTerminalRequest(
        ticket: CmxAttachTicket,
        workspaceSelection: String?,
        terminalSelection: String?
    ) -> Bool {
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing).
        // It covers any workspace/terminal on the paired Mac.
        if ticketWorkspaceID.isEmpty {
            return true
        }
        if let workspaceSelection, workspaceSelection != ticketWorkspaceID {
            return false
        }

        if let ticketTerminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ticketTerminalID.isEmpty {
            return terminalSelection == ticketTerminalID
        }

        return workspaceSelection == ticketWorkspaceID
    }

    private static func containsIgnoredAliasParameters(_ params: [String: Any]) -> Bool {
        params["workspaceID"] != nil || params["terminalID"] != nil
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

    private static func withRequestTimeout<T: Sendable>(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MobileShellConnectionError.requestTimedOut
            }
            do {
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}

#if DEBUG
extension MobileCoreRPCClient {
    /// Test-only hook exposing the private request-timeout race for unit tests.
    public static func debugWithRequestTimeout<T: Sendable>(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withRequestTimeout(
            timeoutNanoseconds: timeoutNanoseconds,
            operation: operation
        )
    }
}
#endif
