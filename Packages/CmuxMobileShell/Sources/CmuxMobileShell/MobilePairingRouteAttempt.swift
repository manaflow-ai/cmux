import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileTransport
import Foundation
import OSLog

// justification: same shared logger shape as MobileShellComposite; Bundle.main
// only seeds the log subsystem string.
private let pairingAttemptLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

/// One `workspace.list` request shape the pairing connect tries on a route.
///
/// Pairing sends up to two shapes per route: the full unscoped list (when the
/// ticket carries an attach token) and the ticket-scoped list (when the ticket
/// names a workspace), so both Mac-wide pairings and single-workspace tickets
/// land on a working list for old and new hosts alike.
struct MobilePairingWorkspaceListRequest: Sendable {
    /// The encoded JSON-RPC request frame.
    let data: Data
    /// Whether this request is scoped to the ticket's workspace (a follow-up
    /// full-list refresh is scheduled after a scoped connect).
    let isScoped: Bool
    /// Whether applying the response should prefer the ticket's target.
    let preferActiveTicketTarget: Bool

    /// The ordered request shapes `connect` tries for `ticket` on each route.
    /// - Parameter ticket: The attach ticket being connected.
    /// - Returns: At least one request; unscoped first when an attach token is
    ///   present, then the ticket-scoped shape when the ticket names a workspace.
    /// - Throws: A serialization error if a request body is not encodable.
    static func initialRequests(for ticket: CmxAttachTicket) throws -> [MobilePairingWorkspaceListRequest] {
        let scopedParams = scopedParams(for: ticket)
        let hasAttachToken = ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        var requests: [MobilePairingWorkspaceListRequest] = []
        if hasAttachToken {
            requests.append(
                MobilePairingWorkspaceListRequest(
                    data: try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:]),
                    isScoped: false,
                    preferActiveTicketTarget: true
                )
            )
        }

        if !scopedParams.isEmpty {
            requests.append(
                MobilePairingWorkspaceListRequest(
                    data: try MobileCoreRPCClient.requestData(method: "workspace.list", params: scopedParams),
                    isScoped: true,
                    preferActiveTicketTarget: true
                )
            )
        }

        if requests.isEmpty {
            requests.append(
                MobilePairingWorkspaceListRequest(
                    data: try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:]),
                    isScoped: false,
                    preferActiveTicketTarget: true
                )
            )
        }
        return requests
    }

    // justification: untyped wire payload mirrors MobileCoreRPCClient.requestData's
    // params carve-out; the wire shape is owned by the RPC layer.
    private static func scopedParams(for ticket: CmxAttachTicket) -> [String: Any] {
        guard UUID(uuidString: ticket.workspaceID) != nil else {
            return [:]
        }
        var params: [String: Any] = ["workspace_id": ticket.workspaceID]
        if let terminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalID.isEmpty {
            params["terminal_id"] = terminalID
        }
        return params
    }
}

/// A single route's pairing attempt, split into the two phases the
/// ``MobilePairingTwoPhaseRace`` orchestrates:
///
/// - ``probe(route:)`` dials the route and sends ONLY the unauthenticated
///   `mobile.host.status` request, so the race can contact many unverified
///   candidate endpoints without handing any of them a credential.
/// - ``finalize(route:client:)`` sends the credentialed initial workspace
///   list shapes over the single winning probe's connection.
///
/// The probe owns its client on failure (disconnects before the error
/// propagates, including cancellation when it loses the race); a successful
/// probe hands ownership to the orchestrator, which tears it down via its
/// discard hook when the probe does not become the final win.
struct MobilePairingRouteAttempt: Sendable {
    /// A successful pairing: the connected client plus the response that proved it.
    struct Win: Sendable {
        /// The route that won.
        let route: CmxAttachRoute
        /// The connected RPC client, ready to be installed as the live connection.
        let client: MobileCoreRPCClient
        /// The decoded initial workspace list.
        let response: MobileSyncWorkspaceListResponse
        /// The request shape that produced ``response``.
        let request: MobilePairingWorkspaceListRequest
    }

    /// The DI runtime supplying the transport factory, auth, and timeouts.
    let runtime: any MobileSyncRuntime
    /// The attach ticket being connected.
    let ticket: CmxAttachTicket
    /// The ordered request shapes to try on the winning route.
    let requests: [MobilePairingWorkspaceListRequest]
    /// Whether the client may fall back to Stack auth on trusted routes.
    let allowsStackAuthFallback: Bool

    /// Dials `route` and proves it speaks the cmux mobile protocol with the
    /// unauthenticated `mobile.host.status` probe. No credential (neither the
    /// Stack bearer token nor the attach ticket's token) is attached:
    /// `mobile.host.status` is the one method exempt from auth on both ends,
    /// so racing this probe across unverified candidate endpoints leaks
    /// nothing to a stale or reassigned address.
    /// - Parameter route: The route to probe.
    /// - Returns: The connected client, ready for ``finalize(route:client:)``.
    /// - Throws: The dial/probe error; the client is disconnected first.
    func probe(route: CmxAttachRoute) async throws -> MobileCoreRPCClient {
        // Refuse to dial a route the finalize could never succeed over: every
        // credentialed request requires the Stack token, and a route outside
        // the trusted set must never carry it. The old sequential loop
        // rejected such routes before dialing (the first credentialed
        // request's auth build threw first); the credential-free probe must
        // not regress that into "contact the host, then fail", so the same
        // policy gate runs pre-dial here. Route-local, like the finalize
        // failure it front-runs: a trusted sibling route still races.
        guard allowsStackAuthFallback,
              MobileShellRouteAuthPolicy.routeAllowsStackAuth(route) else {
            throw MobileShellConnectionError.insecureManualRoute
        }
        pairingAttemptLog.info(
            "pairing probing route kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private)"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: allowsStackAuthFallback
        )
        do {
            _ = try await client.sendRequest(
                try MobileCoreRPCClient.requestData(method: "mobile.host.status"),
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
            )
            return client
        } catch {
            pairingAttemptLog.error(
                "pairing probe failed kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private): \(String(describing: error), privacy: .private)"
            )
            await client.disconnect()
            throw error
        }
    }

    /// Sends the credentialed initial workspace list shapes over the winning
    /// probe's connection and returns the first shape that decodes.
    ///
    /// Does NOT disconnect `client` on failure: the orchestrator owns the
    /// probe's lifecycle and tears it down through its discard hook, keeping a
    /// single owner for the connection.
    /// - Parameters:
    ///   - route: The route `client` is connected over.
    ///   - client: The winning probe's connected client.
    /// - Returns: The win carrying the live connection and decoded list.
    /// - Throws: The last request shape's error.
    func finalize(route: CmxAttachRoute, client: MobileCoreRPCClient) async throws -> Win {
        var lastError: (any Error)?
        for request in requests {
            do {
                let resultData = try await client.sendRequest(
                    request.data,
                    timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
                )
                return Win(
                    route: route,
                    client: client,
                    response: try MobileSyncWorkspaceListResponse.decode(resultData),
                    request: request
                )
            } catch {
                lastError = error
                pairingAttemptLog.error(
                    "pairing route failed kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private) scoped=\(request.isScoped ? 1 : 0, privacy: .public): \(String(describing: error), privacy: .private)"
                )
                guard Self.shouldTryNextRequest(after: error) else { throw error }
            }
        }
        throw lastError ?? MobileShellConnectionError.connectionClosed
    }

    /// Whether the next request shape is worth trying on the same connection.
    ///
    /// A host-level answer (RPC error, auth rejection, undecodable result)
    /// means the connection works and a different request shape may succeed,
    /// for example the ticket-scoped list after the unscoped one is rejected.
    /// A transport failure or timeout means the pipe itself is dead or
    /// unresponsive, so retrying a different shape would only stack a second
    /// timeout onto an attempt that is already lost.
    static func shouldTryNextRequest(after error: any Error) -> Bool {
        if error is CancellationError { return false }
        if error is CmxNetworkByteTransportError { return false }
        if let connectionError = error as? MobileShellConnectionError {
            switch connectionError {
            case .requestTimedOut, .connectionClosed:
                return false
            case .invalidResponse, .insecureManualRoute, .attachTicketExpired,
                 .authorizationFailed, .accountMismatch, .rpcError:
                return true
            }
        }
        return true
    }

    /// Whether a failed attempt ends the whole route race.
    ///
    /// True only for ``MobileShellConnectionError/attachTicketExpired``: it is
    /// checked locally against the device clock before anything is sent, so it
    /// is identical on every route by construction. Every host-ANSWERED
    /// failure stays route-local, including auth rejections
    /// (``MobileShellConnectionError/authorizationFailed``,
    /// ``MobileShellConnectionError/accountMismatch``): the ticket's routes
    /// are unverified candidate endpoints, so a stale or reassigned address
    /// can host a *different* Mac that answers a fast, protocol-valid auth
    /// rejection for a ticket it never minted, while a slower sibling route
    /// would have reached the right Mac and paired (the old sequential loop
    /// kept trying later routes after auth rejections for the same reason).
    /// Treating those answers as race-ending would cancel the viable route
    /// deterministically. When the rejection is genuine, every route fails
    /// with it inside the bounded per-attempt deadlines and
    /// ``MobilePairingRouteRaceFailure/representative`` still surfaces it
    /// (auth answers win representation when they are unanimous across
    /// routes), so the user reads the same error a moment later. Transport failures and
    /// ``MobileShellConnectionError/insecureManualRoute`` also stay
    /// route-local: a sibling route may still reach the host or be trusted to
    /// carry the credential.
    static func failureEndsRouteRace(_ error: any Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError else { return false }
        switch connectionError {
        case .attachTicketExpired:
            return true
        case .authorizationFailed, .accountMismatch, .rpcError, .requestTimedOut,
             .connectionClosed, .invalidResponse, .insecureManualRoute:
            return false
        }
    }
}
