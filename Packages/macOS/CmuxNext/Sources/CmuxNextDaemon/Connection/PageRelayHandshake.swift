import Foundation
import CmuxNextCompat

/// The page relay's handshake (request-origin.md): `identify`, then `client-hello {role:
/// page_relay}` only when the daemon has `origin-claim-v1`, and no label. When the hello names
/// events the page hears (`page-events-v1`), a plain `subscribe` follows: the daemon narrows that
/// stream to those events, and the connection reports each one as it came (``DaemonEvent/raw``),
/// so the relay forwards it without a Swift type per event. The connection is ready, and takes page calls, only after the hello result: a
/// relay request never goes out with a client role. Without the capability the connect fails.
/// Its own type, not a `DaemonConnection` member (that type's line budget is frozen).
enum PageRelayHandshake {
    static func run(_ transport: LineTransport, configuration: DaemonConnectionConfiguration) async throws -> DaemonIdentity {
        let timeout = configuration.requestTimeout
        let first = await transport.pipeline([PipelinedLine(IdentifyRequest())], timeout: timeout)
        let identity = try WireCoding.decodeResponse(IdentifyRequest.Response.self, from: first[0].get())
        guard identity.app == "cmux-tui", identity.protocolVersion == 12 else {
            transport.close()
            throw identity.app == "cmux-tui" ? DaemonError.unsupportedProtocol(identity.protocolVersion) : DaemonError.wrongApp(identity.app)
        }
        guard identity.supports(DaemonClientRole.originClaimCapability) else {
            transport.close()
            throw DaemonError.missingCapabilities([DaemonClientRole.originClaimCapability])
        }
        // The page this relay serves, only to a daemon that knows page ids (an older one would
        // refuse nothing but apply no page list).
        let page = identity.supports(DaemonClientRole.pageRouterCapability) ? configuration.relayIdentity?.page : nil
        let request = ClientHelloRequest(role: .pageRelay, page: page)
        let hello = await transport.pipeline([PipelinedLine(request)], timeout: timeout)
        do {
            let reply = try WireCoding.decodeResponse(ClientHelloRequest.Response.self, from: hello[0].get())
            configuration.relayIdentity?.connectionID = reply.connectionId
            configuration.relayIdentity?.gestureOperations = Set(reply.pageOperations?.gesture ?? [])
            var events = Set(reply.pageEvents ?? [])
            if !events.isEmpty {
                // A refused or failed subscribe leaves the page without live events, never
                // without its calls.
                let subscribed = await transport.pipeline([PipelinedLine(SubscribeRequest(treeEvents: .coarse))], timeout: timeout)
                if (try? WireCoding.decodeResponse(EmptyResponse.self, from: subscribed[0].get())) == nil { events = [] }
            }
            configuration.relayIdentity?.events = events
            return identity
        } catch {
            transport.close()
            throw error
        }
    }
}

/// The page relay connection's daemon id from `client-hello` (a confirmation token is bound to it),
/// shared between the connection's handshake and the relay that issues tokens, with the page it
/// serves and that page's gesture operations from the hello reply (`page-router-v1`).
public final class PageRelayIdentity: Sendable {
    private let value = Mutex<String?>(nil)
    private let gestures = Mutex<Set<String>>([])
    private let pageEvents = Mutex<Set<String>>([])
    /// The page id (`history`), or nil for a relay that serves no one page.
    public let page: String?

    public init(page: String? = nil) {
        self.page = page
    }

    public var connectionID: String? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }

    /// The subscribe events the page hears on this relay (`history-changed`).
    public var events: Set<String> {
        get { pageEvents.withLock { $0 } }
        set { pageEvents.withLock { $0 = newValue } }
    }

    /// The operations the page may call only on the person's gesture.
    public var gestureOperations: Set<String> {
        get { gestures.withLock { $0 } }
        set { gestures.withLock { $0 = newValue } }
    }
}

extension DaemonEvent {
    /// One subscribe-stream line as the daemon sent it (`.unknown` with its whole object): what a
    /// page relay connection reports, so the relay forwards events without a Swift type for each.
    static func raw(name: String, line: Data, decoder: WireDecoder = WireCoding.decoder()) -> DaemonEvent {
        .unknown(name: name, payload: (try? decoder.decode(JSONValue.self, from: line)) ?? .null)
    }
}
