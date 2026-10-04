import Foundation

/// The link of one Cloud machine for its daemon connection (C13b). A
/// ``connect(origin:)`` (one user intent, a fresh idempotency key: the daemon
/// replays a keyed `apps-run`) asks the resolver for the socket, and
/// ``endpoint()`` hands that socket to exactly one connection. v1 does not
/// reconnect by itself: a second ``endpoint()`` call (the connection
/// reconnecting after a drop), a `down` or `revoked` change, or a failed
/// connect ends the link until the next connect.
public actor CloudLinkSession {
    enum State {
        case idle
        case connecting
        case ready(CloudLinkSocket)
        case attached(CloudLinkSocket)
        case ended(CloudLinkError)
    }

    public nonisolated let key: CloudLinkKey
    private let resolver: any CloudLinkResolver
    private let makeIntent: @Sendable () -> String
    private var state = State.idle
    /// Counts connects and closes; an older connect's answer is dropped.
    private var attempt = 0

    /// `intent` makes each connect's idempotency key (default: a new UUID).
    public init(key: CloudLinkKey, resolver: any CloudLinkResolver, intent: (@Sendable () -> String)? = nil) {
        self.key = key
        self.resolver = resolver
        makeIntent = intent ?? { UUID().uuidString }
    }

    /// True once the link ended (the connection needs a new connect).
    public var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    /// Opens the link for one connection. Throws ``CloudLinkError``; a
    /// connect that a later connect or ``close()`` superseded throws
    /// `disconnected` and changes nothing.
    @discardableResult
    public func connect(origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        attempt += 1
        let mine = attempt
        state = .connecting
        let result: Result<CloudLinkSocket, CloudLinkError>
        do {
            result = .success(try await resolver.open(key, intent: makeIntent(), origin: origin))
        } catch let error as CloudLinkError {
            result = .failure(error)
        } catch {
            result = .failure(.failed(code: "", message: String(describing: error)))
        }
        guard attempt == mine else { throw CloudLinkError.disconnected(reason: "superseded") }
        switch result {
        case .success(let socket):
            state = .ready(socket)
            return socket
        case .failure(let error):
            state = .ended(error)
            throw error
        }
    }

    /// The daemon connection's endpoint: the socket of the last connect,
    /// once. Throws ``CloudLinkError`` otherwise and ends the link.
    public func endpoint() throws -> String {
        switch state {
        case .ready(let socket):
            state = .attached(socket)
            return socket.path
        case .attached:
            let error = CloudLinkError.disconnected(reason: "connection ended")
            state = .ended(error)
            throw error
        case .ended(let error):
            throw error
        case .idle, .connecting:
            throw CloudLinkError.disconnected(reason: "not connected")
        }
    }

    /// Applies a link change. True when it ended this link, so its
    /// connection must close. `up`, another machine, and a change of an
    /// older carrier generation change nothing.
    public func apply(_ change: CloudLinkChange) -> Bool {
        guard change.key == key, change.state != .up else { return false }
        let socket: CloudLinkSocket
        switch state {
        case .ready(let current), .attached(let current): socket = current
        case .idle, .connecting, .ended: return false
        }
        if let changed = change.generation, let current = socket.generation, changed < current { return false }
        let reason = change.reason ?? change.state.rawValue
        state = .ended(change.state == .revoked ? .revoked(reason: reason) : .disconnected(reason: reason))
        return true
    }

    /// Ends the link without an op (the machine paused: its link ends on
    /// the server side too).
    public func end(reason: String) {
        attempt += 1
        state = .ended(.disconnected(reason: reason))
    }

    /// Ends the link for good and asks the app server to close it.
    public func close() async {
        end(reason: "closed")
        await resolver.close(key)
    }
}
