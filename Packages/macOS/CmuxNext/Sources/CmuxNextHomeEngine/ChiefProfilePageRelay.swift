public import CmuxNextDaemon
import CmuxNextIPC
public import CmuxNextWakeups
public import Foundation
import os

/// The home-channels page's Chief profile calls (`cmux.chief.profile.*`, hq-ec's New Chief, edit
/// and archive sheets; chief-profile-ws-v1) go to this build's Chief OWNER, where the Chiefs live,
/// not to the build daemon. Route and confirm only, no profile logic (the owner decides):
///
/// - Every call goes on one `home-channels` page stream of the owner's page-relay connection
///   (``PageRelayStream``), so the owner judges it with origin `page:home-channels`
///   and that page's allow list (cmux-tui spec/page-router.json). The relay opens no connection
///   itself: ``ChiefProfileRelayOwner/pageRelay(socket:)`` is the owner daemon's page relay.
/// - The stream's epoch (pid, generation, hello id) is the owner check: a stream of another owner
///   process than the one the app's main connection is attached to takes no call, and a call goes
///   once more on a new stream when its stream ended under it (the owner restarted).
/// - A call the owner takes only on the person's gesture (create, delete, undo, and an update
///   that names a gesture field) goes out as the user only when a real key or pointer event backs it,
///   one event per call: the host asks `origin.confirmation.issue` on its own trusted connection
///   to the owner (the app's verified main connection) for a token bound to the op, its exact
///   params and this stream. Without that event the call goes as the page, and the
///   owner refuses it (`origin.forbidden`, `gesture_required`).
@MainActor
public final class ChiefProfilePageRelay {
    /// The ops the page may send here (page-router.json, home-channels).
    public static let operations: Set<String> = [
        "chief.profile.list", "chief.profile.get", "chief.profile.create", "chief.profile.update",
        "chief.profile.delete", "chief.profile.avatar.get", "chief.profile.avatar.set",
        // The Chief editor's History and Undo (docs/chiefs-create-byo-backend.md).
        "chief.profile.history", "chief.profile.undo",
    ]
    /// The update fields the owner changes only on the person's gesture (cmux-tui-core
    /// chief_registry.rs `GESTURE_FIELDS`); `locked` is the person's switch.
    static let gestureFields: Set<String> = [
        "effort", "harness", "harnesses", "instructions", "locked", "model", "personality", "self_edit", "tools",
    ]
    /// The page id of the stream (page-router.json).
    public nonisolated static let page = "home-channels"

    private weak var owner: (any ChiefProfileRelayOwner)?
    /// Ends the page stream ``PageRelayIdleClose/delay`` after the last call ends:
    /// Home and Settings > Agents > Chiefs hold no page-relay client on the owner while nobody uses
    /// the editor, closed or frozen. The editor has no listens; the next call opens a new stream.
    private let idle: PageRelayIdleClose
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "chief-profile-relay")
    private let clock: any Clock<Duration>
    /// Every page call answers within this, also when a step below it never does: the page's
    /// sheet then clears busy and shows the error (`cmux.protocol.timeout`). Each step has the
    /// 2 s request deadline: a stream open (identify, hello, subscribe: 6 s), a confirmation and
    /// the call (4 s), so 10 s per attempt and 16 s leave room for the one reopen.
    nonisolated static let callDeadline: Duration = .seconds(16)

    /// The owner process the app's main connection is attached to: a restarted owner (same
    /// socket, new process) is another owner, and its page calls go on a stream to it.
    struct OwnerKey: Equatable, Sendable {
        var socket: String
        var pid: Int32
        var generation: DaemonGeneration
    }

    private var stream: (any PageRelayStream)?
    private var opening: (task: Task<any PageRelayStream, any Error>, owner: OwnerKey)?
    /// The event uptime of the last gesture a call spent.
    private var spentGesture: TimeInterval?

    /// The relay of `owner`; the app's page host keeps one per owner, so its pages' calls share one
    /// page stream to the owner.
    ///
    /// - Parameters:
    ///   - owner: This build's Chief owner.
    ///   - idle: The one-shot deadline of the stream's idle close (a background `MainDeadline`).
    public convenience init(owner: ChiefConversationOwner, idle: any PageRelayIdleDeadline) {
        self.init(owner: owner as any ChiefProfileRelayOwner, idle: idle)
    }

    init(owner: any ChiefProfileRelayOwner, clock: any Clock<Duration> = ContinuousClock(), idle: any PageRelayIdleDeadline) {
        self.owner = owner
        self.clock = clock
        self.idle = PageRelayIdleClose(deadline: idle)
        self.idle.onIdle = { [weak self] in self?.dropStream() }
    }

    /// Whether the owner takes `operation` with `params` from the page only on a gesture.
    static func needsGesture(_ operation: String, params: [String: JSONValue]) -> Bool {
        switch operation {
        // An undo may set any field back, gesture fields included: always the person's click.
        case "chief.profile.create", "chief.profile.delete", "chief.profile.undo": true
        case "chief.profile.update": !gestureFields.isDisjoint(with: params.keys)
        default: false
        }
    }

    /// One page call to the owner. `gestureEvent`: the uptime of the real key or pointer event
    /// that backs this call (`PageCallContext.gestureEvent`), nil without one. It always answers
    /// within ``callDeadline``: the owner's result, its refusal, or a typed error.
    public func send(operation: String, params: [String: JSONValue], idempotencyKey: String?,
                     gestureEvent: TimeInterval?) async throws -> JSONValue {
        guard Self.operations.contains(operation) else { throw DaemonError.command(cmd: operation, message: "not a Chief profile operation", code: "unknown_op") }
        // One gesture backs one call; a reopen inside this call may use it again.
        let gesture = Self.needsGesture(operation, params: params) && gestureEvent != nil && gestureEvent != spentGesture
        if gesture { spentGesture = gestureEvent }
        let started = ContinuousClock.now
        let elapsed = { Int((ContinuousClock.now - started) / .milliseconds(1)) }
        logger.info("\(operation, privacy: .public): start, gesture \(gesture)")
        do {
            let result = try await PageCallDeadline.answer(within: Self.callDeadline, clock: clock, onTimeout: { [weak self] in
                // A step that never answered: the next call starts on a new stream.
                self?.dropStream()
                return DaemonError.timedOut("\(operation) (no answer from the Chief owner within \(Self.callDeadline))")
            }) { [self] in
                // The work, not the answer, uses the stream: a step the deadline gave up on still
                // holds it until it ends.
                idle.begin()
                defer { idle.end() }
                return try await call(operation: operation, params: params, idempotencyKey: idempotencyKey, gesture: gesture)
            }
            logger.info("\(operation, privacy: .public): answered in \(elapsed()) ms")
            return result
        } catch {
            logger.info("\(operation, privacy: .public): failed in \(elapsed()) ms: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// The call on the page stream to the current owner; once more on a new stream when that
    /// stream ended under it (the owner restarted). A mutation carries its idempotency key, so
    /// the owner applies it once.
    private func call(operation: String, params: [String: JSONValue], idempotencyKey: String?, gesture: Bool) async throws -> JSONValue {
        // Two attempts at most: the second only after the first lost its stream.
        for attempt in 1...2 {
            guard let owner, let attached = await owner.attachedOwner() else { throw DaemonError.notConnected }
            var used: (any PageRelayStream)?
            do {
                let stream = try await pageStream(to: attached, of: owner)
                used = stream
                // A call the deadline already answered sends nothing more: a late create after the
                // page showed the timeout would make a Chief the person was told failed.
                try Task.checkCancellation()
                var origin = JSONValue.object(["claim": .string("page")])
                if gesture {
                    let token = try await confirmationToken(owner: owner, stream: stream, operation: operation, params: params)
                    origin = .object(["claim": .string("user"), "confirmation": .string(token)])
                }
                try Task.checkCancellation()
                return try await stream.send(operation: operation, params: params, idempotencyKey: idempotencyKey, origin: origin)
            } catch let error as DaemonError where attempt == 1 && Self.isConnectionLost(error) {
                logger.info("\(operation, privacy: .public): page stream lost (\(error.description, privacy: .public)); again on a new one")
                if let used, self.stream === used { dropStream() }
            }
        }
        // Not reached: the second attempt returns or throws.
        throw DaemonError.notConnected
    }

    nonisolated static func isConnectionLost(_ error: DaemonError) -> Bool {
        switch error {
        case .notConnected, .connectionClosed, .daemonShutdown: true
        default: false
        }
    }

    /// Ends the page stream; the next call opens one again.
    private func dropStream() {
        guard let stream else { return }
        self.stream = nil
        // task-owner: one close of a stream no call uses any more (off main: the stream is its own)
        closing = Task { @concurrent in await stream.close() }
    }

    /// The last stream close (``dropStream()``); tests await it.
    private(set) var closing: Task<Void, Never>?

    /// The `home-channels` stream to `attached`, the owner process the app's main connection is
    /// attached to now; a new one when that owner restarted or the stream ended.
    private func pageStream(to attached: OwnerKey, of owner: any ChiefProfileRelayOwner) async throws -> any PageRelayStream {
        if let stream, stream.epoch.serves(pid: attached.pid, generation: attached.generation), await stream.isOpen {
            return stream
        }
        // An open to the same owner in flight is shared; one to another owner is not.
        if let opening, opening.owner == attached { return try await opening.task.value }
        let relay = owner.pageRelay(socket: attached.socket)
        // task-owner: one stream open; ends with its handshake (each line has the request deadline). Off main: it
        // touches only the relay and its stream; the caller checks the owner again in its resume.
        let task = Task { @concurrent () async throws -> any PageRelayStream in
            let opened = try await relay.openStream(page: Self.page)
            // The socket may already serve another owner process than the one the app's main
            // connection is attached to (it restarted in between): that is not this owner.
            guard opened.epoch.serves(pid: attached.pid, generation: attached.generation) else {
                await opened.close()
                throw DaemonError.notConnected
            }
            return opened
        }
        opening = (task, attached)
        defer { if opening?.owner == attached { opening = nil } }
        let made = try await task.value
        // An open to an older owner that finished after a newer one started is not used: the
        // call goes once more, to the owner the main connection is attached to now.
        guard opening?.owner == attached else {
            await made.close()
            throw DaemonError.notConnected
        }
        let old = stream
        stream = made
        if let old, old !== made { await old.close() }
        return made
    }

    /// `origin.confirmation.issue` on the app's trusted main connection to the owner: a
    /// single-use token for exactly this op, its params (canonical SHA-256 as sent) and `stream`'s
    /// connection (its epoch's hello id).
    private func confirmationToken(owner: any ChiefProfileRelayOwner, stream: any PageRelayStream, operation: String,
                                   params: [String: JSONValue]) async throws -> String {
        let request = V2OriginConfirmationIssueRequest(
            operation: operation, paramsSha256: try ResourceRelayClient.paramsDigest(params, operation: operation),
            relayConnectionID: stream.epoch.connectionID)
        return try await owner.issueConfirmation(request).token
    }
}

/// What the relay needs of the Chief owner: the owner process its trusted main connection is
/// attached to, that connection's confirmations, and the owner daemon's page-relay connection.
@MainActor
protocol ChiefProfileRelayOwner: AnyObject {
    /// The owner process the main connection is attached to now; nil while it is not.
    func attachedOwner() async -> ChiefProfilePageRelay.OwnerKey?
    /// `origin.confirmation.issue` on the trusted main connection.
    func issueConfirmation(_ request: V2OriginConfirmationIssueRequest) async throws -> V2OriginConfirmation
    /// The page-relay connection of the owner daemon at `socket`.
    func pageRelay(socket: String) -> any PageRelayStreamOpening
}

extension ChiefConversationOwner: ChiefProfileRelayOwner {
    func attachedOwner() async -> ChiefProfilePageRelay.OwnerKey? {
        guard let identity, let socket = await socketPath() else { return nil }
        return ChiefProfilePageRelay.OwnerKey(socket: socket, pid: identity.pid, generation: identity.generation)
    }

    func issueConfirmation(_ request: V2OriginConfirmationIssueRequest) async throws -> V2OriginConfirmation {
        guard let connection else { throw DaemonError.notConnected }
        return try await ResourceOperationClient(connection: connection).read(request, as: V2OriginConfirmation.self)
    }

    func pageRelay(socket: String) -> any PageRelayStreamOpening {
        PageRelayDedicatedStreams(clientName: "cmux-next-chief-profile-relay", retryWake: nil,
                                  endpointProvider: { DaemonEndpoint(socketPath: socket) })
    }
}
