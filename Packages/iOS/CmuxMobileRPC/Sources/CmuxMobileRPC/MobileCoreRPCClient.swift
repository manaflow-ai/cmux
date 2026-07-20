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
    private static let independentEventPreparationTimeoutNanoseconds: UInt64 = 3_000_000_000
    private let runtime: any MobileSyncRuntime
    private let route: CmxAttachRoute
    private let ticket: CmxAttachTicket
    private let transportRequest: CmxByteTransportRequest
    /// The attach ticket this client uses to authorize RPC requests.
    public var attachTicket: CmxAttachTicket { ticket }
    private let allowsStackAuthFallback: Bool
    // `internal` (not `private`) so `@testable import` can observe session
    // queue state from tests, instead of exposing a debug hook in production.
    let session: MobileCoreRPCSession
    private let stackTokenGate: RPCStackTokenGate
    private let stackTokenForceRefreshGate: RPCStackTokenGate
    private let lifecycleGate: MobileRPCClientLifecycleGate

    /// Create a client bound to one route + attach ticket.
    /// - Parameters:
    ///   - runtime: The DI runtime supplying transport factory, token provider, timeouts, clock.
    ///   - route: The attach route this client connects over.
    ///   - ticket: The attach ticket authorizing requests.
    ///   - allowsStackAuthFallback: When `true`, falls back to a Stack Auth token
    ///     on routes that allow it once the attach ticket no longer covers a request.
    ///   - legacyTailscaleAuthorizationEvidence: Exact local capability retained
    ///     only for a pairing that predates Iroh. Mismatched evidence is ignored,
    ///     leaving the raw Tailscale route fail-closed.
    ///   - transportConnectObserver: Optional synchronous sink for privacy-safe
    ///     transport dial lifecycle events. The observer must return immediately.
    public init(
        runtime: any MobileSyncRuntime,
        route: CmxAttachRoute,
        ticket: CmxAttachTicket,
        allowsStackAuthFallback: Bool = false,
        legacyTailscaleAuthorizationEvidence: CmxLegacyTailscaleAuthorizationEvidence? = nil,
        connectAttemptRegistry: MobileRPCConnectAttemptRegistry = MobileRPCConnectAttemptRegistry(),
        stackTokenGate: RPCStackTokenGate? = nil,
        stackTokenForceRefreshGate: RPCStackTokenGate? = nil,
        abandonedConnectCleanupTimeoutNanoseconds: UInt64 = 1_000_000_000,
        lateAbandonedConnectCloseTimeoutNanoseconds: UInt64 = 5_000_000_000,
        stackTokenGateResetNanoseconds: UInt64 = 30_000_000_000,
        transportConnectObserver: (@Sendable (MobileRPCTransportConnectEvent) -> Void)? = nil,
        sessionPurpose: CmxTransportSessionPurpose = .foregroundControl
    ) {
        self.runtime = runtime
        self.route = route
        self.ticket = ticket
        let authorizationMode: CmxTransportAuthorizationMode
        if route.kind == .iroh {
            authorizationMode = .transportAdmission
        } else if route.kind == .tailscale,
                  case let .hostPort(host, port) = route.endpoint,
                  let legacyTailscaleAuthorizationEvidence,
                  legacyTailscaleAuthorizationEvidence.authorizes(
                      macDeviceID: ticket.macDeviceID,
                      host: host,
                      port: port
                  ) {
            authorizationMode = .legacyTailscaleBearer(
                legacyTailscaleAuthorizationEvidence
            )
        } else {
            authorizationMode = .stackBearer
        }
        let transportRequest = CmxByteTransportRequest(
            route: route,
            expectedPeerDeviceID: ticket.macDeviceID,
            authorizationMode: authorizationMode,
            sessionPurpose: sessionPurpose
        )
        self.transportRequest = transportRequest
        self.allowsStackAuthFallback = allowsStackAuthFallback
        let lifecycleGate = MobileRPCClientLifecycleGate()
        self.lifecycleGate = lifecycleGate
        self.stackTokenGate = stackTokenGate
            ?? RPCStackTokenGate(timedOutResetNanoseconds: stackTokenGateResetNanoseconds)
        self.stackTokenForceRefreshGate = stackTokenForceRefreshGate
            ?? RPCStackTokenGate(timedOutResetNanoseconds: stackTokenGateResetNanoseconds)
        let independentEventFactory: MobileCoreRPCSession.IndependentEventByteStreamFactory?
        if route.kind == .iroh,
           let provider = runtime.independentEventByteStreamProvider {
            independentEventFactory = {
                let admission = try lifecycleGate.beginIndependentEventAdmission()
                let stream = try await provider(transportRequest)
                return try await lifecycleGate.finishIndependentEventAdmission(
                    admission,
                    stream: stream
                )
            }
        } else {
            independentEventFactory = nil
        }
        self.session = MobileCoreRPCSession(
            connectAttemptKey: route.mobileRPCConnectAttemptKey,
            connectAttemptRegistry: connectAttemptRegistry,
            abandonedConnectCleanupTimeoutNanoseconds: abandonedConnectCleanupTimeoutNanoseconds,
            lateAbandonedConnectCloseTimeoutNanoseconds: lateAbandonedConnectCloseTimeoutNanoseconds,
            makeTransport: { [runtime, transportRequest, lifecycleGate] in
                try lifecycleGate.makeTransport {
                    try runtime.transportFactory.makeTransport(for: transportRequest)
                }
            },
            makeIndependentEventByteStream: independentEventFactory,
            diagnosticTransport: route.kind.diagnosticTransportKind,
            transportConnectObserver: transportConnectObserver
        )
    }

    /// Tear down the persistent transport (called when the client is
    /// replaced or the user signs out).
    public func disconnect() async {
        retire()
        await session.tearDown(error: .connectionClosed)
    }

    /// Synchronously prevent this client from allocating another transport.
    /// Shell ownership changes call this before scheduling actor-isolated
    /// teardown, closing the window where an already-queued RPC could reopen a
    /// client that is no longer authoritative.
    public func retire() {
        lifecycleGate.retire()
    }

    /// Subscribe to server-pushed events. Returns a stream of envelopes
    /// matching any of the requested topics. Cancel by terminating iteration.
    public func subscribe(to topics: Set<String>) async -> AsyncStream<MobileEventEnvelope> {
        await session.addEventListener(topics: topics).stream
    }

    /// Starts the optional Iroh server-event lane before advertising support to
    /// the host. Returns `false` on unsupported routes or setup failure so the
    /// caller can retain control-stream event delivery.
    public func prepareIndependentServerEvents() async -> Bool {
        await session.prepareIndependentServerEvents()
    }

    /// Opens an artifact lane bound to this client's immutable admitted route.
    public func openArtifactLane(
        resourceID: String,
        offset: UInt64
    ) async throws -> any MobileArtifactLaneConnection {
        guard route.kind == .iroh,
              let provider = runtime.artifactLaneProvider else {
            throw MobileShellConnectionError.connectionClosed
        }
        let admission = try lifecycleGate.beginArtifactLaneAdmission()
        let connection = try await provider(
            transportRequest,
            resourceID,
            offset
        )
        return try await lifecycleGate.finishArtifactLaneAdmission(
            admission,
            connection: connection
        )
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
        try await sendRequestOperation(
            requestData,
            timeoutNanoseconds: timeoutNanoseconds
        ).response
    }

    /// Sends an authorized request and then proves host identity with the same
    /// Stack token that authorized its successful response.
    ///
    /// The token stays in this call frame. Failed, cancelled, and concurrent
    /// requests cannot publish or overwrite authorization state for a later
    /// host-status probe.
    public func sendRequestAndAuthenticatedHostStatus(
        _ requestData: Data,
        timeoutNanoseconds: UInt64? = nil,
        hostStatusTimeoutNanoseconds: @Sendable () -> UInt64? = { nil }
    ) async throws -> (response: Data, hostStatusResponse: Data) {
        guard let request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              Self.requestRequiresAuth(request) else {
            throw MobileShellConnectionError.invalidResponse
        }
        let authorized = try await sendRequestOperation(
            requestData,
            timeoutNanoseconds: timeoutNanoseconds
        )
        let hostStatusTimeout = hostStatusTimeoutNanoseconds()
        if hostStatusTimeout == 0 {
            throw MobileShellConnectionError.requestTimedOut
        }
        let hostStatus = try await sendRequestOperation(
            Self.requestData(method: "mobile.host.status", params: [:]),
            timeoutNanoseconds: hostStatusTimeout,
            hostStatusStackToken: authorized.stackAccessToken
        )
        return (authorized.response, hostStatus.response)
    }

    private func sendRequestOperation(
        _ requestData: Data,
        timeoutNanoseconds: UInt64?,
        hostStatusStackToken: String? = nil
    ) async throws -> AuthenticatedRequestResult {
        let deadline = RPCRequestDeadline(
            timeoutNanoseconds: timeoutNanoseconds ?? runtime.rpcRequestTimeoutNanoseconds
        )
        let preparedRequest = await requestAdvertisingIndependentEvents(
            requestData,
            deadline: deadline
        )
        do {
            return try await sendAuthenticatedRequest(
                preparedRequest,
                deadline: deadline,
                allowAuthRetry: true,
                hostStatusStackToken: hostStatusStackToken
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
            guard transportUsesStackBearer,
                  case .authorizationFailed = error else { throw error }
            try await forceRefreshStackTokenForRetry(deadline: deadline)
            // Re-run with retry disabled so a fresh token that is still rejected
            // surfaces as a definitive auth failure instead of looping.
            return try await sendAuthenticatedRequest(
                preparedRequest,
                deadline: deadline,
                allowAuthRetry: false,
                hostStatusStackToken: hostStatusStackToken
            )
        }
    }

    /// Adds the rolling-compatible opt-in only after the Iroh accept owner is
    /// installed. Older hosts ignore the field and continue control delivery.
    private func requestAdvertisingIndependentEvents(
        _ requestData: Data,
        deadline: RPCRequestDeadline
    ) async -> Data {
        guard var request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              request["method"] as? String == "mobile.events.subscribe",
              var params = request["params"] as? [String: Any],
              params["event_transport"] == nil,
              let streamID = params["stream_id"] as? String,
              let remaining = try? deadline.remainingNanoseconds() else {
            return requestData
        }
        let preparationTimeout = min(
            remaining,
            Self.independentEventPreparationTimeoutNanoseconds
        )
        guard await session.prepareIndependentServerEvents(
            forSubscriptionStreamID: streamID,
            timeoutNanoseconds: preparationTimeout
        ) else {
            return requestData
        }
        params["event_transport"] = "iroh_server_events_v1"
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request)) ?? requestData
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
        hostStatusStackToken: String?
    ) async throws -> AuthenticatedRequestResult {
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
            hostStatusStackToken: hostStatusStackToken
        )
        try Task.checkCancellation()
        let response = try await session.send(
            payload: authenticated.data,
            requestID: id,
            deadlineUptimeNanoseconds: deadline.uptimeNanoseconds
        )
        return AuthenticatedRequestResult(
            response: response,
            stackAccessToken: authenticated.stackAccessToken
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

    private func requestDataWithAuth(
        _ requestData: Data,
        deadline: RPCRequestDeadline,
        hostStatusStackToken: String?
    ) async throws -> AuthenticatedRequestPayload {
        guard var request = try JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return AuthenticatedRequestPayload(data: requestData, stackAccessToken: nil)
        }
        if transportRequest.authorizationMode == .transportAdmission {
            request.removeValue(forKey: "auth")
            return AuthenticatedRequestPayload(
                data: try JSONSerialization.data(withJSONObject: request),
                stackAccessToken: nil
            )
        }
        let requestNeedsAuth = Self.requestRequiresAuth(request)
        let requestIsCoveredByAttachTicket = !Self.requestNeedsStackAuthFallback(request, ticket: ticket)
        var auth: [String: Any] = [:]
        var requestStackAccessToken: String?
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
            } else if !canSendStackBearer {
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
            guard canSendStackBearer else {
                throw MobileShellConnectionError.insecureManualRoute
            }
            do {
                let token = try await stackAccessToken(deadline: deadline)
                auth["stack_access_token"] = token
                requestStackAccessToken = token
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
           canSendStackBearer {
            let stackAccessToken: String?
            if let hostStatusStackToken {
                stackAccessToken = hostStatusStackToken
            } else {
                stackAccessToken = try await stackAccessTokenForStatus(deadline: deadline)
            }
            if let stackAccessToken {
                auth["stack_access_token"] = stackAccessToken
            }
        }
        if !auth.isEmpty {
            request["auth"] = auth
        }
        return AuthenticatedRequestPayload(
            data: try JSONSerialization.data(withJSONObject: request),
            stackAccessToken: requestStackAccessToken
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

    private var transportUsesStackBearer: Bool {
        switch transportRequest.authorizationMode {
        case .stackBearer, .legacyTailscaleBearer:
            true
        case .transportAdmission:
            false
        }
    }

    /// One authorization decision shared by every token-send site. Generic
    /// plaintext routes remain restricted to loopback; the legacy mode is valid
    /// only while its immutable device/IP/port evidence still matches.
    private var canSendStackBearer: Bool {
        switch transportRequest.authorizationMode {
        case .stackBearer:
            return allowsStackAuthFallback
                && MobileShellRouteAuthPolicy.routeAllowsStackAuth(route)
        case let .legacyTailscaleBearer(evidence):
            guard route.kind == .tailscale,
                  case let .hostPort(host, port) = route.endpoint else {
                return false
            }
            return evidence.authorizes(
                macDeviceID: ticket.macDeviceID,
                host: host,
                port: port
            )
        case .transportAdmission:
            return false
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
        case "mobile.workspace.list", "workspace.list",
             "mobile.directory.list", "mobile.directory.search":
            return false
        case "workspace.create":
            return false
        case "workspace.action", "workspace.close":
            return !ticketCoverage.ticketCoversWorkspaceRequest(
                ticket: ticket,
                workspaceSelection: workspaceSelection.value
            )
        case "workspace.move", "workspace.group.action", "workspace.group.create":
            // These mutations are Mac-scoped. Always preserve the attach-ticket
            // context when one exists so the host can reject workspace-scoped
            // tickets instead of receiving a Stack-only request.
            return false
        case "mobile.terminal.create", "terminal.create":
            return false
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.paste", "terminal.paste",
             "mobile.terminal.paste_image", "terminal.paste_image",
             "mobile.terminal.replay", "terminal.replay",
             "mobile.terminal.viewport", "terminal.viewport",
             "mobile.terminal.artifact.scan",
             "mobile.terminal.artifact.stat",
             "mobile.terminal.artifact.fetch",
             "mobile.terminal.artifact.thumbnail":
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

    private struct AuthenticatedRequestPayload {
        let data: Data
        let stackAccessToken: String?
    }

    private struct AuthenticatedRequestResult {
        let response: Data
        let stackAccessToken: String?
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
