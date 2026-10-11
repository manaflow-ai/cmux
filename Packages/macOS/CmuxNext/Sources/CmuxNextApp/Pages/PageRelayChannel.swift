import CmuxNextDaemon
import CmuxNextPages
import Foundation
import os

/// The daemon side of React page calls (SECURITY, request-origin.md): page ops go on their own
/// daemon connection with the `page_relay` role, so the daemon derives origin `page` for every
/// one of them, whatever a Swift bug sends. A call is the user's only after a native sheet
/// approved it: the relay asks the main connection for a one-time confirmation token bound to
/// the op, its exact params and this relay connection, and attaches it to that one request. The
/// page never sees the token.
///
/// Against a daemon without `origin-claim-v1` there is no relay connection: page calls go on the
/// main connection as before, with a logged warning that they are not narrowed.
@MainActor
final class PageRelayChannel {
    private static let logger = Logger(subsystem: "dev.cmux.next", category: "page-relay")
    private static var channels: [ObjectIdentifier: PageRelayChannel] = [:]

    /// The channel of the local daemon service (one relay connection per app).
    static func shared(for service: DaemonService) -> PageRelayChannel {
        let key = ObjectIdentifier(service)
        if let channel = channels[key] { return channel }
        let channel = PageRelayChannel(service: service)
        channels[key] = channel
        return channel
    }

    private weak var service: DaemonService?
    private var relay: DaemonConnection?
    private let identity = PageRelayIdentity()
    private var starting: Task<DaemonConnection, any Error>?
    private var warned = false

    init(service: DaemonService) {
        self.service = service
    }

    /// One page call: the v2 op `operation` with `params`, as `page`, or as the user with a token
    /// when `context` was confirmed on a native sheet.
    func send(operation: String, params: [String: CmuxNextDaemon.JSONValue], idempotencyKey: String?,
              context: PageCallContext) async throws -> CmuxNextDaemon.JSONValue {
        guard let service, let main = service.connection else { throw DaemonError.notConnected }
        guard service.supports(DaemonClientRole.originClaimCapability) else {
            if !warned {
                warned = true
                Self.logger.warning("the daemon has no origin-claim-v1: page calls are not narrowed to origin page")
            }
            return try await ResourceRelayClient(connection: main).send(operation: operation, params: params, idempotencyKey: idempotencyKey)
        }
        let relay = try await relayConnection(service)
        var origin = CmuxNextDaemon.JSONValue.object(["claim": .string("page")])
        if context.isConfirmedUser {
            let token = try await confirmationToken(main: main, relay: relay, operation: operation, params: params)
            origin = .object(["claim": .string("user"), "confirmation": .string(token)])
        }
        return try await ResourceRelayClient(connection: relay).send(
            operation: operation, params: params, idempotencyKey: idempotencyKey, origin: origin)
    }

    /// The relay connection; it takes page calls only after its `client-hello` result.
    private func relayConnection(_ service: DaemonService) async throws -> DaemonConnection {
        if let relay, await relay.isReady { return relay }
        if let starting { return try await starting.value }
        guard let endpoint = service.endpointProvider else { throw DaemonError.notConnected }
        let configuration = DaemonConnection.Configuration(clientName: "cmux-next-page-relay", retryWake: service.retryWake,
                                                           terminalEnvironment: nil, role: .pageRelay, relayIdentity: identity)
        let task = Task { () async throws -> DaemonConnection in
            let connection = DaemonConnection(configuration: configuration, endpointProvider: endpoint)
            try await connection.start()
            return connection
        }
        starting = task
        defer { starting = nil }
        let connection = try await task.value
        relay = connection
        return connection
    }

    /// `origin.confirmation.issue` on the main connection: a single-use token for exactly this
    /// op, params (their canonical SHA-256 as sent) and relay connection.
    private func confirmationToken(main: DaemonConnection, relay: DaemonConnection, operation: String,
                                   params: [String: CmuxNextDaemon.JSONValue]) async throws -> String {
        guard let relayID = identity.connectionID else { throw DaemonError.notConnected }
        let issued = try await ResourceRelayClient(connection: main).send(
            operation: "origin.confirmation.issue",
            params: ["operation": .string(operation), "params_sha256": .string(try ResourceRelayClient.paramsDigest(params)),
                     "relay_connection_id": .string(relayID)],
            idempotencyKey: nil)
        guard case .object(let members) = issued, case .string(let token)? = members["token"] else {
            throw DaemonError.malformedResponse("origin.confirmation.issue")
        }
        return token
    }
}
