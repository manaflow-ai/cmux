import Foundation
import Synchronization

/// The page relay's handshake (request-origin.md): `identify`, then `client-hello {role:
/// page_relay}` only when the daemon has `origin-claim-v1`, and nothing else (no label, no
/// subscribe). The connection is ready, and takes page calls, only after the hello result: a
/// relay request never goes out with a client role. Without the capability the connect fails.
/// Its own type, not a `DaemonConnection` member (that type's line budget is frozen).
enum PageRelayHandshake {
    static func run(_ transport: LineTransport, configuration: DaemonConnectionConfiguration) async throws -> DaemonIdentity {
        let timeout = configuration.requestTimeout
        let first = await transport.pipeline([PipelinedLine(IdentifyRequest())], timeout: timeout)
        let identity = try WireCoding.decodeResponse(IdentifyRequest.Response.self, from: first[0].get().line)
        guard identity.app == "cmux-tui", identity.protocolVersion == 12 else {
            transport.close()
            throw identity.app == "cmux-tui" ? DaemonError.unsupportedProtocol(identity.protocolVersion) : DaemonError.wrongApp(identity.app)
        }
        guard identity.supports(DaemonClientRole.originClaimCapability) else {
            transport.close()
            throw DaemonError.missingCapabilities([DaemonClientRole.originClaimCapability])
        }
        let hello = await transport.pipeline([PipelinedLine(ClientHelloRequest(role: .pageRelay))], timeout: timeout)
        do {
            let reply = try WireCoding.decodeResponse(ClientHelloRequest.Response.self, from: hello[0].get().line)
            configuration.relayIdentity?.connectionID = reply.connectionId
            return identity
        } catch {
            transport.close()
            throw error
        }
    }
}

/// The page relay connection's daemon id from `client-hello` (a confirmation token is bound to it),
/// shared between the connection's handshake and the relay that issues tokens.
public final class PageRelayIdentity: Sendable {
    private let value = Mutex<String?>(nil)

    public init() {}

    public var connectionID: String? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
