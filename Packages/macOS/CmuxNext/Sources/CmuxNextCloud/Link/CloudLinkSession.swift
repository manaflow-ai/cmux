public import CmuxNextDaemon
import Foundation

/// The link of one Cloud machine for its daemon connection (C13b). A
/// ``connect(origin:)`` (one user intent, a fresh idempotency key: the daemon
/// replays a keyed `apps-run`) asks the resolver for the socket and returns a
/// ``CloudLinkTicket``; ``endpoint(_:)`` with that ticket hands the socket to
/// exactly one connection. A second ``endpoint(_:)`` call (the connection
/// retrying a first handshake, or reconnecting after a drop) gets the same
/// socket again from a link that dials per connection (the carrier,
/// ``CloudLinkResolver/redials``) until it refused a dial; from any other link
/// it ends the link. A `down` or `revoked` change, or a failed connect, ends
/// the link until the next connect. A ticket of an older connect never changes
/// the state: an old connection that asks again only learns that it was
/// superseded.
public actor CloudLinkSession {
    enum State {
        case idle
        case connecting
        case ready(CloudLinkSocket)
        case attached(CloudLinkSocket)
        case ended(CloudLinkError)
    }

    public nonisolated let key: CloudLinkKey
    /// ``ownerLink`` != nil for the main actor (Settings > Machines' row), on the same link.
    public nonisolated let ownership = CloudLinkOwnership()
    private let resolver: any CloudLinkResolver
    private let makeIntent: @Sendable () -> String
    private var state = State.idle {
        didSet {
            published += 1
            let (ownership, owns, link) = (ownership, ownerLink != nil, published)
            // task-owner: one main-actor hop; CloudLinkOwnership drops one a newer hop overtook
            Task { @MainActor in ownership.publish(owns, link: link) }
        }
    }
    /// Counts state changes: the order of the ``ownership`` hops.
    private var published = 0
    /// Counts connects and ends; the current connect's ticket id.
    private var attempt: UInt64 = 0
    /// A revoke that came while the current connect was in flight: the
    /// connect's answer cannot bring the link back.
    private var revokedWhileConnecting: CloudLinkError?
    /// The resolver hands newer ownership answers to ``updateOwnership(_:)`` (asked once).
    private var observing = false

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
        revokedWhileConnecting = nil
        if !observing {
            observing = true
            await resolver.observeOwnership(key) { [weak self] in await self?.updateOwnership($0) }
        }
        var result: Result<CloudLinkSocket, CloudLinkError>
        do {
            result = .success(try await resolver.open(key, intent: makeIntent(), origin: origin))
        } catch let error as CloudLinkError {
            result = .failure(error)
        } catch {
            result = .failure(.failed(code: "", message: String(describing: error)))
        }
        guard attempt == mine else { throw Self.superseded }
        if let revoked = revokedWhileConnecting {
            revokedWhileConnecting = nil
            result = .failure(revoked)
        }
        switch result {
        case .success(let socket):
            state = .ready(socket)
            return CloudLinkTicket(id: mine, socket: socket)
        case .failure(let error):
            state = .ended(error)
            throw error
        }
    }

    /// The current connect's socket while its link is up, without handing it to a connection:
    /// ``endpoint(_:)`` still serves it once. For another, short-lived client of the same machine
    /// daemon (`cmux link machine update`), also while the app refused that daemon: the carrier
    /// dials the machine once per connection it accepts (``CloudCarrierServe``). Nil before a
    /// connect answered and once the link ended.
    public var currentSocket: String? {
        switch state {
        case .ready(let socket), .attached(let socket): socket.path
        case .idle, .connecting, .ended: nil
        }
    }

    /// One atomic snapshot of the live endpoint and its ownership answer. Reading these
    /// separately could combine a replacement socket with a superseded owner answer.
    public var currentLinkSocket: CloudLinkSocket? {
        switch state {
        case .ready(let socket), .attached(let socket): socket
        case .idle, .connecting, .ended: nil
        }
    }

    /// The current connect's id while its link is up and its answer said the signed-in caller owns
    /// the machine (``CloudLinkSocket/callerOwnsVM``), else nil. A chat start or a trust call reads
    /// it before it connects and again as it sends: a different answer means the link ended or a
    /// new connect asked the Cloud API again, so an owner answer never carries over to another link
    public var ownerLink: Int? {
        switch state {
        case .ready(let socket), .attached(let socket): socket.callerOwnsVM ? Int(truncatingIfNeeded: attempt) : nil
        case .idle, .connecting, .ended: nil
        }
    }

    /// What this link's connect answered about the signed-in caller: ``CloudCallerOwnership/unknown`` while no
    /// link is up, or when the answer was neither `owner` nor `team` (the app server could not read it, or predates it).
    public var callerOwnership: CloudCallerOwnership {
        switch state {
        case .ready(let socket), .attached(let socket): socket.callerOwnsVM ? .owner : socket.callerIsTeammate ? .team : .unknown
        case .idle, .connecting, .ended: .unknown
        }
    }

    /// The link's state in one word, for a decision log line (no id, path or token).
    public var stateWord: String {
        switch state {
        case .idle: "idle"
        case .connecting: "connecting"
        case .ready: "ready"
        case .attached: "attached"
        case .ended: "ended"
        }
    }

    /// True while the link is up and its connect's answer said the machine is a teammate's
    /// (``CloudLinkSocket/callerIsTeammate``): a chat start is refused as a teammate's machine
    /// (`agent_session.team_vm_blocked`). It never grants a start; only ``ownerLink`` does.
    public var callerIsTeammate: Bool {
        switch state {
        case .ready(let socket), .attached(let socket): socket.callerIsTeammate
        case .idle, .connecting, .ended: false
        }
    }

    /// The daemon connection's endpoint: the ticket's socket. Throws
    /// ``CloudLinkError`` otherwise; a current ticket's second call ends the
    /// link unless the link redials (see the type), an old ticket changes nothing.
    public func endpoint(_ ticket: CloudLinkTicket) async throws -> String {
        guard ticket.id == attempt else { throw Self.superseded }
        switch state {
        case .ready(let socket):
            state = .attached(socket)
            return socket.path
        case .attached(let socket):
            // A refused connection's step (a carrier dial's), else the plain drop. A link that dials per
            // connection serves the retry until it refused one.
            let refusal = await resolver.refusal(key)
            guard ticket.id == attempt, case .attached = state else { throw Self.superseded }
            if refusal == nil, resolver.redials { return socket.path }
            let error = refusal ?? CloudLinkError.disconnected(reason: "connection ended")
            state = .ended(error)
            throw error
        case .ended(let error):
            throw error
        case .idle, .connecting:
            throw CloudLinkError.disconnected(reason: "not connected")
        }
    }

    /// The ticket's socket for one more connection to the machine's daemon (an agent chat's attach,
    /// the history reader): each connection to the carrier's socket is its own dial, so this neither
    /// attaches nor ends the link. Only the daemon connection's own redial goes through
    /// ``endpoint(_:)``, whose second call is that connection dropping.
    public func streamEndpoint(_ ticket: CloudLinkTicket) throws -> String {
        guard ticket.id == attempt else { throw Self.superseded }
        switch state {
        case .ready(let socket), .attached(let socket): return socket.path
        case .ended(let error): throw error
        case .idle, .connecting: throw CloudLinkError.disconnected(reason: "not connected")
        }
    }

    /// A newer answer about the caller for the live link (a carrier connection's `vmk`): the link's
    /// ownership follows it without a new connect. Nothing while no link is up or when it is the same.
    func updateOwnership(_ caller: CloudCallerOwnership) {
        guard caller != callerOwnership else { return }
        let owned = { (socket: CloudLinkSocket) in
            CloudLinkSocket(key: socket.key, path: socket.path, generation: socket.generation,
                            callerOwnsVM: caller == .owner, callerIsTeammate: caller == .team)
        }
        switch state {
        case .ready(let socket): state = .ready(owned(socket))
        case .attached(let socket): state = .attached(owned(socket))
        case .idle, .connecting, .ended: break
        }
    }

    /// Applies a link change. Returns the ticket id of the link it ended (its
    /// connection must close), or nil. `up`, another machine, a change of an
    /// older carrier generation, and a `down` while a connect is in flight
    /// (its answer names the carrier that counts) change nothing. A revoke
    /// while a connect is in flight ends that connect when it answers.
    public func apply(_ change: CloudLinkChange) -> UInt64? {
        guard change.key == key, change.state != .up else { return nil }
        let socket: CloudLinkSocket
        switch state {
        case .ready(let current), .attached(let current): socket = current
        case .connecting:
            if change.state == .revoked { revokedWhileConnecting = .revoked(reason: change.reason ?? change.state.rawValue) }
            return nil
        case .idle, .ended: return nil
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

    /// Ends the link and stops the machine's `carrier serve` child, keeping the link reusable (the machine
    /// paused). A child left running keeps resuming its relay session on its cached ticket, which never asks
    /// the platform, and that traffic wakes a VM its person paused. The next connect starts a fresh child,
    /// whose first dial the platform judges (a person's pause refuses it).
    public func park(reason: String) async {
        end(reason: reason)
        await resolver.close(key)
    }

    /// The machine's carrier socket for the Cloud app server (``CloudLinkResolver/carrierSocket(_:)``): it
    /// neither connects nor ends this link.
    public func carrierSocket() async throws -> String { try await resolver.carrierSocket(key) }

    /// The Cloud app server's carrier ask (``CloudCredentialRelay/carrierSocketOp``) of `machine`, whose app
    /// link is `link` (nil: this app has no session of it), as the relay's answer: the socket path, or the
    /// carrier step that refused (``CloudCarrierDial/carrierRefusal(_:)``). `paused`: the machine is paused or
    /// pausing, so the ask is refused as `cloud.machine.paused` without starting a serve child: a chat stream's
    /// retry would otherwise respawn the serve a pause just stopped, and its dial would wake the machine.
    public static func carrierAnswer(_ link: CloudLinkSession?, machine: String, paused: Bool = false) async -> Result<String, CloudCredentialRelay.CarrierRefusal> {
        guard let link else { return .failure(.init(code: "cloud.machine.not_found", message: "this Mac has no session of \(machine)")) }
        if paused { return .failure(.init(code: "cloud.machine.paused", message: "\(machine) is paused; resume it first")) }
        do { return .success(try await link.carrierSocket()) } catch { return .failure(CloudCarrierDial.carrierRefusal(error)) }
    }

    /// Ends the link for good and stops the machine's `carrier serve` (machine removed, sign-out, quit).
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

/// Who the signed-in caller is to a machine, by its link's connect answer: its owner, a teammate, or not known (no link
/// up, or no answer read). Only `owner` grants anything; `unknown` is never read as a teammate's machine.
public enum CloudCallerOwnership: String, Sendable {
    case owner, team, unknown
}
