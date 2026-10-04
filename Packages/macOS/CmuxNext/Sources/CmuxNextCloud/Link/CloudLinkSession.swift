import Foundation

/// The link of one Cloud machine for its daemon connection (C13b). A
/// ``connect(origin:)`` (one user intent, a fresh idempotency key: the daemon
/// replays a keyed `apps-run`) asks the resolver for the socket and returns a
/// ``CloudLinkTicket``; ``endpoint(_:)`` with that ticket hands the socket to
/// exactly one connection. v1 does not reconnect by itself: a second
/// ``endpoint(_:)`` call (the connection reconnecting after a drop, also after
/// a first handshake that failed), a `down` or `revoked` change, or a failed
/// connect ends the link until the next connect. A ticket of an older connect
/// never changes the state: an old connection that asks again only learns
/// that it was superseded.
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
    /// Counts connects and ends; the current connect's ticket id.
    private var attempt: UInt64 = 0

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
    /// connect that a later connect or an end superseded throws
    /// `disconnected` and changes nothing.
    @discardableResult
    public func connect(origin: CloudLinkOrigin) async throws -> CloudLinkTicket {
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
        guard attempt == mine else { throw Self.superseded }
        switch result {
        case .success(let socket):
            state = .ready(socket)
            return CloudLinkTicket(id: mine, socket: socket)
        case .failure(let error):
            state = .ended(error)
            throw error
        }
    }

    /// The daemon connection's endpoint: the ticket's socket, once. Throws
    /// ``CloudLinkError`` otherwise; a current ticket's second call ends the
    /// link, an old ticket changes nothing.
    public func endpoint(_ ticket: CloudLinkTicket) throws -> String {
        guard ticket.id == attempt else { throw Self.superseded }
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

    /// Applies a link change. Returns the ticket id of the link it ended (its
    /// connection must close), or nil. `up`, another machine, a change of an
    /// older carrier generation, and a change while a connect is in flight
    /// (its answer names the carrier that counts) change nothing.
    public func apply(_ change: CloudLinkChange) -> UInt64? {
        guard change.key == key, change.state != .up else { return nil }
        let socket: CloudLinkSocket
        switch state {
        case .ready(let current), .attached(let current): socket = current
        case .idle, .connecting, .ended: return nil
        }
        if let changed = change.generation, let current = socket.generation, changed < current { return nil }
        let reason = change.reason ?? change.state.rawValue
        state = .ended(change.state == .revoked ? .revoked(reason: reason) : .disconnected(reason: reason))
        return attempt
    }

    /// Ends the link without an op (the machine paused: its link ends on
    /// the server side too). Every ticket so far is superseded.
    public func end(reason: String) {
        attempt += 1
        state = .ended(.disconnected(reason: reason))
    }

    /// Ends the link for good and asks the app server to close it.
    public func close() async {
        end(reason: "closed")
        await resolver.close(key)
    }

    private static let superseded = CloudLinkError.disconnected(reason: "superseded")
}

/// One connect of a ``CloudLinkSession``: its socket, and the id that
/// tells this connect's connection from an older one.
public struct CloudLinkTicket: Equatable, Sendable {
    public let id: UInt64
    public let socket: CloudLinkSocket
}
