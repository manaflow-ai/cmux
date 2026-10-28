public import Foundation

/// `tailnet.*`: this install's own device on the person's tailnet, an embedded Tailscale node the
/// daemon owns (a daemon half that is not on this branch yet). Only the verified app's own control
/// connection may call them. A daemon without the node refuses them (an unknown operation, or
/// `operation.failed` reason `not_built`); the caller shows that as unavailable.
///
/// The state's shape is decoded by the caller (`S`): `{state, browse_to_url?, dns_name?,
/// owner?: {login_name, display_name}, ips?, error?}`. `browse_to_url` is a credential until it is
/// used (whoever opens it first owns the device): never log it.
public struct TailnetNodeClient: Sendable {
    public let connection: DaemonConnection

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    /// `tailnet.login.start`: starts the node when it does not run and answers its state, with
    /// the sign-in link while it needs a login. The daemon waits up to 20 s for that link.
    public func loginStart<S: Decodable & Sendable>(as type: S.Type) async throws -> S {
        try await mutation("tailnet.login.start", as: type)
    }

    /// `tailnet.logout`: the device leaves the tailnet; answers the state after it.
    public func logout<S: Decodable & Sendable>(as type: S.Type) async throws -> S {
        try await mutation("tailnet.logout", as: type)
    }

    /// `tailnet.state`: the current state, then one item per change of the node (no polling),
    /// decoded on the connection's reader thread (an item that is not `S` is skipped). Ends when
    /// the daemon ends the stream or the connection closes.
    public func states<S: Decodable & Sendable>(as type: S.Type) async throws -> AsyncStream<S> {
        try await connection.resourceStream(operation: "tailnet.state", params: [:], as: type)
    }

    private func mutation<S: Decodable & Sendable>(_ operation: String, as type: S.Type) async throws -> S {
        let key = "cmux-next-\(operation)-" + UUID().uuidString.lowercased()
        // The node answers after the control plane does (sign-in link, logout): up to 20 s.
        return try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: [:], idempotencyKey: key)
        }, as: ResourceMutationResult<S>.self, timeout: .seconds(30)).value
    }
}
