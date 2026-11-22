public import Foundation
import CmuxNextWakeups
import os

/// Auto chat placement's hands in the app (design/auto-chat-placement.md, "Moving a running chat").
/// The daemon decides where an Auto chat runs (acpmux `chat_place.rs`); this only carries out what it
/// says, through the moves the chat's own Move to… menu runs (`run`: Move to Cloud, Bring Back Local).
/// A move to or from a joined machine the daemon runs itself (`acpmux session move`). It holds no rule
/// of its own.
///
/// - Its own connection to this app's acpmux, on the unix socket with the server peer checked
///   (``AcpmuxCheckedLine``), hears `chatPlace/move {session, to, peer, why, back}` and hands each to `run`.
/// - System sleep (lid closed, idle or menu sleep, ``ChatPlaceSleepGate``) tells the daemon
///   `_acpmux/place_chat_event {kind: "willSleep"}`, so the decision sees `power.sleeping` and moves
///   the chats off this Mac, then holds sleep until the moves the daemon started have ended
///   (`_acpmux/place_chat_settled`), at most ``sleepHold``; wake says `didWake`.
@MainActor
public final class AcpmuxChatPlaceMover {
    /// Where a move takes a chat, as the daemon names it.
    public enum Place: String, Sendable { case local, peer, cloud }

    /// One `chatPlace/move {session, to, peer, why, back}`.
    public struct Move: Equatable, Sendable {
        public let session: String
        public let to: Place
        public let peer: String?
        public let why: String
        /// It brings the chat back to where it started.
        public let back: Bool

        public init(session: String, to: Place, peer: String? = nil, why: String = "", back: Bool = false) {
            (self.session, self.to, self.peer, self.why, self.back) = (session, to, peer, why, back)
        }

        /// The move from a notification's params; nil for anything else.
        public init?(params: [String: Any]) {
            guard let session = params["session"] as? String, !session.isEmpty,
                  let to = (params["to"] as? String).flatMap(Place.init(rawValue:)) else { return nil }
            let peer = (params["peer"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if to == .peer, peer == nil { return nil }
            self.init(session: session, to: to, peer: peer, why: params["why"] as? String ?? "",
                      back: params["back"] as? Bool ?? false)
        }

        /// The machine the chat's Move to… takes (``AgentPaneMoveTarget``): this Mac's id (Bring Back), or ""
        /// for any Cloud machine (Move to Cloud with no machine named). nil for a joined machine: the daemon
        /// moves those chats itself (`acpmux session move`), never through the app.
        public var target: String? {
            switch to {
            case .local: AgentPaneMoveTarget.localID
            case .cloud: ""
            case .peer: nil
            }
        }
    }

    /// The notification.
    public static let moveMethod = "chatPlace/move"
    /// The longest sleep is held for the moves: macOS sleeps anyway 30 s after it asked.
    public static let sleepHold: Duration = .seconds(25)

    private let environment: AcpmuxEnvironment
    private let run: @MainActor (Move) -> Bool
    private var connection: AcpmuxCheckedLine?
    private var reconnect: Task<Void, Never>?
    private var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
    private var nextID = 10
    private var replies: [Int: CheckedContinuation<Data?, Never>] = [:]
    private var sleepGate: ChatPlaceSleepGate?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "acpmux.chat-place")

    /// `run` starts the move and answers whether it started.
    public init(environment: AcpmuxEnvironment, run: @escaping @MainActor (Move) -> Bool) {
        (self.environment, self.run) = (environment, run)
    }

    /// Connects and registers for system sleep (idempotent).
    public func start() {
        if sleepGate == nil {
            let gate = ChatPlaceSleepGate(willSleep: { [weak self] in await self?.willSleep() },
                                          didWake: { [weak self] in Task { _ = await self?.event("didWake") } }) // task-owner: one didWake request per wake
            if gate.start() { sleepGate = gate } else { logger.error("chat place: no system power notifications") }
        }
        guard connection == nil, reconnect == nil else { return }
        connect()
    }

    nonisolated deinit {
        reconnect?.cancel()
        connection?.cancel()
        // The gate deregisters on main, where it lives; the hop holds it until then.
        if let gate = sleepGate { MainDelivery().run { gate.stop() } }
    }

    /// The Mac goes to sleep: the daemon hears it, then sleep waits for the moves it started.
    func willSleep() async {
        let clock = ContinuousClock(), started = clock.now
        _ = await event("willSleep")
        let left = Self.sleepHold - (clock.now - started)
        guard left > .zero else { return }
        let millis = left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000
        let moving = await call("_acpmux/place_chat_settled", ["waitMs": millis])?["moving"] as? [String] ?? []
        if !moving.isEmpty { logger.info("chat place: sleeping with \(moving.count, privacy: .public) moves unfinished") }
    }

    /// `_acpmux/place_chat_event {kind}`; whether the daemon took it.
    func event(_ kind: String) async -> Bool {
        await call("_acpmux/place_chat_event", ["kind": kind]) != nil
    }

    // MARK: acpmux

    private func connect() {
        reconnect = nil
        // An absent socket fails the connect on the line's own queue, which closes it: `lost` waits and tries again.
        let line = AcpmuxCheckedLine(environment: environment)
        connection = line
        line.start(send: Data(acpmuxRequest: 1, method: "initialize", params: [
            "protocolVersion": 1, "clientInfo": ["name": "cmux-next-chat-place", "version": "1"],
            "clientCapabilities": [String: Any](),
        ]), onLine: { [weak self] data in MainDelivery().run { self?.handle(data) } },
           onClose: { [weak self] in MainDelivery().run { self?.lost(line) } })
    }

    private func lost(_ line: AcpmuxCheckedLine) {
        guard connection === line else { return }
        connection = nil
        for (_, waiter) in replies { waiter.resume(returning: nil) }
        replies = [:]
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnect?.cancel()
        // task-owner: AcpmuxChatPlaceMover.reconnect: one backoff wait after a lost or absent socket.
        reconnect = Task { [weak self] in
            guard var backoff = self?.backoff else { return }
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "acpmux-chat-place.reconnect") } catch { return }
            self?.backoff = backoff
            self?.connect()
        }
    }

    /// One request on the mover's connection; its result, nil when it closed or failed.
    private func call(_ method: String, _ params: [String: Any]) async -> [String: Any]? {
        guard let connection else { return nil }
        nextID += 1
        let id = nextID, data = Data(acpmuxRequest: id, method: method, params: params)
        let reply: Data? = await withCheckedContinuation { waiter in
            replies[id] = waiter
            connection.send(data)
        }
        return reply.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    private func handle(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let id = (message["id"] as? NSNumber)?.intValue {
            if id == 1 { backoff.reset(); return }
            guard let waiter = replies.removeValue(forKey: id) else { return }
            waiter.resume(returning: message["error"] == nil
                ? try? JSONSerialization.data(withJSONObject: message["result"] as? [String: Any] ?? [:]) : nil)
            return
        }
        guard message["method"] as? String == Self.moveMethod,
              let move = (message["params"] as? [String: Any]).flatMap(Move.init(params:)) else { return }
        if !run(move) {
            logger.info("chat place: no move started for \(move.to.rawValue, privacy: .public) (\(move.why, privacy: .public))")
        }
    }
}
