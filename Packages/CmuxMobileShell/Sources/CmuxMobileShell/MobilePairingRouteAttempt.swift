import CMUXMobileCore
import CmuxMobileRPC
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

/// A single route's pairing attempt: dial, send the initial workspace list
/// shapes, decode the first success.
///
/// Owns the client lifecycle for the attempt: on any failure (including
/// cancellation when this attempt loses the ``MobilePairingRouteRace``) the
/// client is disconnected before the error propagates, so a losing route never
/// leaks its transport. On success the live client is handed back in ``Win``.
struct MobilePairingRouteAttempt: Sendable {
    /// A successful attempt: the connected client plus the response that proved it.
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
    /// The ordered request shapes to try on the route.
    let requests: [MobilePairingWorkspaceListRequest]
    /// Whether the client may fall back to Stack auth on trusted routes.
    let allowsStackAuthFallback: Bool

    /// Dials `route` and returns the first request shape that decodes.
    /// - Parameter route: The route to attempt.
    /// - Returns: The win carrying the connected client.
    /// - Throws: The last request's error; the client is disconnected first.
    func run(route: CmxAttachRoute) async throws -> Win {
        pairingAttemptLog.info(
            "pairing trying route kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private)"
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: allowsStackAuthFallback
        )
        do {
            return try await send(over: client, route: route)
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private func send(over client: MobileCoreRPCClient, route: CmxAttachRoute) async throws -> Win {
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
    /// True only for failures that are route-independent: an expired ticket
    /// (checked locally, identical on every route) and explicit credential
    /// rejections (auth failure, account mismatch), which are about the
    /// ticket/identity rather than the path that carried it. A generic
    /// ``MobileShellConnectionError/rpcError`` stays route-local even though it
    /// is a host answer: the ticket's routes are unverified candidate
    /// endpoints, so a stale address, the wrong service on an advertised port,
    /// or an older host can answer a fast RPC error on one route while a
    /// sibling route would have connected (the old sequential loop kept trying
    /// the next route after RPC errors for the same reason). Transport
    /// failures and ``MobileShellConnectionError/insecureManualRoute`` also
    /// stay route-local: a sibling route may still reach the host or be
    /// trusted to carry the credential.
    static func failureEndsRouteRace(_ error: any Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError else { return false }
        switch connectionError {
        case .authorizationFailed, .accountMismatch, .attachTicketExpired:
            return true
        case .rpcError, .requestTimedOut, .connectionClosed, .invalidResponse, .insecureManualRoute:
            return false
        }
    }
}
