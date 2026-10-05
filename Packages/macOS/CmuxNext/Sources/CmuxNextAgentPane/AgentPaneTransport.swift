public import Foundation
import os
import Synchronization

/// Why the host's socket refused a page frame or stopped. The raw value is the code the page
/// receives (a bridge failure, or `closed.error` of a transport event).
public nonisolated enum AgentPaneTransportError: String, Error, Equatable, Sendable {
    /// `transport.open` without a handshake that named a daemon (or its connection was used).
    case noConnection = "transport.no_connection"
    case connectFailed = "transport.connect_failed"
    /// A send or close for a connection that is not the current one.
    case staleConnection = "transport.stale_connection"
    case closed = "transport.closed"
    case invalidFrame = "transport.invalid_frame"
    case frameTooLarge = "transport.frame_too_large"
    case firstFrameNotInitialize = "transport.first_frame"
    /// The method is not on ``AcpmuxPaneMethods``.
    case methodRefused = "transport.method_refused"
    /// `transport.gesture` params break the intent contract (``AgentPaneGestureIntent``), a
    /// redeeming frame carries other `_meta` (R1), or a method other than set_mode and
    /// set_config_option names a mode field (P1).
    case intentInvalid = "transport.intent_invalid"
    /// A mode, or a config option that is not free, which the daemon does not say keeps the
    /// session asking, without the user's confirmation (R2, P2).
    case modeNotConfirmed = "transport.mode_not_confirmed"
    /// A page request whose id (JSON value and type) is still waiting for its reply.
    case requestIdInFlight = "transport.request_id_in_flight"
    /// One object of the frame holds two keys that decode to the same string (ad349, round 7).
    case duplicateKey = "transport.duplicate_key"
    /// The frame grants (allows a permission, trusts a folder, prompts, sets a mode) without a
    /// fresh user gesture; the socket stays open.
    case gestureRequired = "transport.gesture_required"
    /// The frame carries `mcpServers` entries ({command, args, env}): the page may not make the
    /// harness spawn a command (C1).
    case mcpServersRefused = "transport.mcp_servers_refused"
    /// A `cwd` or `path` param that is not an absolute existing path (a `cwd` must be a directory).
    case pathInvalid = "transport.path_invalid"
    /// A `cwd` or `path` param outside the pane's workspace roots (``AcpmuxPathPolicy``).
    case pathOutsideRoots = "transport.path_outside_roots"
    /// A kill or permission answer for a session this pane did not start and does not show.
    case sessionNotInPane = "transport.session_not_in_pane"
    /// The page did not take frames as fast as the daemon sent them; the socket was closed.
    case inboundOverflow = "transport.inbound_overflow"
    /// The daemon did not take the page's frames; the socket was closed.
    case outboundOverflow = "transport.outbound_overflow"
}

/// How the socket ended: the close code and reason, and the host's error when the host closed it.
public nonisolated struct AgentPaneTransportClose: Equatable, Sendable {
    public var code: Int
    public var reason: String
    public var error: AgentPaneTransportError?
}

/// One push to the page: frames in arrival order, then (at most once) the close.
public nonisolated struct AgentPaneTransportEvent: Equatable, Sendable {
    public var connection: Int
    public var frames: [String]
    public var closed: AgentPaneTransportClose?

    var object: [String: Any] {
        var object: [String: Any] = ["connection": connection]
        if !frames.isEmpty { object["frames"] = frames }
        if let closed {
            var close: [String: Any] = ["code": closed.code, "reason": closed.reason]
            if let error = closed.error { close["error"] = error.rawValue }
            object["closed"] = close
        }
        return object
    }

    /// The old host's push: `cmuxAcpmuxTransport.receive(event)` (bridgeSocket.ts).
    var script: String {
        let json = (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "window.cmuxAcpmuxTransport?.receive(\(json));"
    }
}

/// What one flush did: whether it made a bridge call (``AgentPaneTransportPacer/delivered()``
/// follows when the page has run it) and whether frames are still waiting.
public nonisolated struct AgentPaneFlush: Equatable, Sendable {
    public var delivered: Bool
    public var more: Bool
    public init(delivered: Bool, more: Bool) {
        self.delivered = delivered
        self.more = more
    }
}

/// When the transport delivers what arrived. Production delivers at once when idle and coalesces
/// only under load (``AgentPaneFramePacer``); tests flush on the next main-loop turn or by hand.
@MainActor public protocol AgentPaneTransportPacer: AnyObject {
    /// Frames arrived: arrange for `flush` to run, and again while it reports more waiting.
    func schedule(_ flush: @escaping @MainActor @Sendable () -> AgentPaneFlush)
    /// The page has run the last call `flush` made.
    func delivered()
    /// The connection changed or closed: forget what was in flight.
    func reset()
}

public extension AgentPaneTransportPacer {
    func delivered() {}
    func reset() {}
}

/// Flushes on the next main-loop turn, again while more is waiting.
@MainActor public final class AgentPaneNextTurnPacer: AgentPaneTransportPacer {
    private var scheduled = false
    public init() {}

    public func schedule(_ flush: @escaping @MainActor @Sendable () -> AgentPaneFlush) {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.scheduled = false
                if flush().more { self?.schedule(flush) }
            }
        }
    }
}

/// The host side of the pane's acpmux connection (design B, localapp-isolation-spike.md): the
/// host owns the WebSocket, puts the LocalApp token in the first frame, checks every page frame
/// against ``AcpmuxPaneMethods`` and relays frames both ways through the page bridge. The page
/// world never sees an endpoint or a token.
///
/// - One connection at a time; `open` closes the previous one. Each has an id the page names.
/// - Inbound frames queue off the main thread in a bounded queue and reach the page in batches,
///   one bridge call per flush (``pacer``). Overflow closes the socket with
///   ``AgentPaneTransportError/inboundOverflow``; the page then reconnects and resyncs.
/// - Outbound sends are bounded too (``AgentPaneTransportError/outboundOverflow``).
/// - Nothing here blocks the main thread: the socket's callbacks run on its own queue.
@MainActor public final class AgentPaneTransport {
    public nonisolated struct Limits: Sendable {
        public var maximumQueuedFrames = 8192
        public var maximumQueuedBytes = 32 << 20
        public var maximumFramesPerFlush = 512
        public var maximumBytesPerFlush = 4 << 20
        public var maximumOutstandingSends = 8192
        public var maximumOutstandingBytes = 64 << 20
        public var connectTimeout: TimeInterval = 10
        public init() {}
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.transport")
    public let limits: Limits
    /// Gets each push for the page (the view sends it through the bridge) and a completion to call
    /// once the page has run it (it paces the next push).
    public var deliver: (@MainActor (AgentPaneTransportEvent, _ done: @escaping @MainActor @Sendable () -> Void) -> Void)?
    /// Counts pushes, so a late completion of a previous connection's push is ignored.
    private var deliveries = 0
    public var pacer: any AgentPaneTransportPacer
    private var socket: AcpmuxPaneSocket?
    private var current = 0
    /// Held from `open` until the first frame is sent, then dropped.
    private var localAppToken: String?
    private var sentFirst = false
    /// The user's gestures in this pane; a granting frame consumes one.
    public let gestures: AgentPaneUserGestures
    /// The permission options the daemon sent, to tell an allow from a deny.
    public let permissionOptions = AcpmuxPermissionOptions()
    /// The sessions this pane started or shows.
    public let sessions = AcpmuxPaneSessions()
    /// The pane's own roots (``AcpmuxPathPolicy/Scope/roots``), asked at each frame.
    public var roots: @MainActor () -> [String] = { [] }
    /// Folders that are roots only when the user picks one by a gesture (the new tab page's scan).
    public var gestureRoots: @MainActor () -> [String] = { [] }
    /// The pane's workspace root, the cwd of a `session/new` that names none.
    public var primaryRoot: @MainActor () -> String? = { nil }
    /// Asks the user to add a refused folder as a root (a native sheet); the answer is true for
    /// Add. Asked only after a real gesture, one at a time.
    public var requestRoot: (@MainActor (_ folder: String, _ answer: @escaping @MainActor (Bool) -> Void) -> Void)?
    /// Folders the user added or picked by a gesture: roots from then on.
    public private(set) var addedRoots: [String] = []
    private var askingRoot = false
    /// Whether the daemon's asking table (acpmux `web_modes.rs`) lists `mode` for the session's
    /// family: true or false, nil when it cannot tell (which needs the confirmation, fail closed).
    /// The host's default asks the daemon over its unix socket (`_acpmux/web_modes`).
    public var webModes: @MainActor (_ sessionId: String?, _ configId: String?, _ value: String?) async -> AcpmuxWebModes? = { _, _, _ in nil }
    /// The daemon's mode fields for this connection (asked at open): an extra deny inside the
    /// known-params rule (``AcpmuxPaneMethods/knownParams``), which applies on every path.
    public private(set) var modeFields: Set<String>?
    /// Shows the native sheet that confirms a mode which does not ask; Cancel answers false.
    public var requestModeConfirmation: (@MainActor (_ asked: AgentPaneModeConfirmation, _ answer: @escaping @MainActor (Bool) -> Void) -> Void)?
    /// The app-wide gate: one mode confirmation open at a time, across all panes and windows.
    public var confirmationGate = AgentPaneConfirmationGate.shared
    /// The current socket's request ids (relay-owned, mapped back on the reply).
    private var requestIds: AcpmuxRequestIds?
    private var socketPath: String?

    /// Pushes and flushes so far (tests and the bench read them).
    public private(set) var flushes = 0

    public init(limits: Limits = Limits(), pacer: (any AgentPaneTransportPacer)? = nil,
                gestures: AgentPaneUserGestures = AgentPaneUserGestures()) {
        self.limits = limits
        self.gestures = gestures
        self.pacer = pacer ?? AgentPaneNextTurnPacer()
        webModes = { [weak self] session, configId, value in
            guard let path = self?.socketPath else { return nil }
            return await AcpmuxStatusClient.webModes(socketPath: path, sessionId: session, configId: configId, value: value)
        }
    }

    public var connection: Int? { socket == nil ? nil : current }

    /// Frames waiting for the page (tests and the bench).
    var queuedFrames: Int { socket?.queuedFrames ?? 0 }

    /// Opens a new socket (closing the current one) and returns its id once it is open.
    public func open(_ connection: AcpmuxConnection) async throws(AgentPaneTransportError) -> Int {
        close(connection: current)
        pacer.reset()
        // A reconnect drops every ticket of the old connection.
        gestures.clearTickets()
        current += 1
        let id = current
        localAppToken = connection.localAppToken
        socketPath = connection.socketPath
        sentFirst = false
        let ids = AcpmuxRequestIds()
        requestIds = ids
        let socket = AcpmuxPaneSocket(request: connection.request, limits: limits, options: permissionOptions, sessions: sessions,
                                      ids: ids) { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.arrived(id) } }
        }
        self.socket = socket
        do {
            try await socket.start(timeout: limits.connectTimeout)
        } catch {
            if self.socket === socket { self.socket = nil; localAppToken = nil }
            Self.logger.error("agent pane transport connect failed connection=\(id, privacy: .public)")
            throw .connectFailed
        }
        guard self.socket === socket else { throw .staleConnection }
        // P1: the daemon's mode fields, once per connection, before the page's first frame.
        modeFields = nil
        let answer = await webModes(nil, nil, nil)
        guard self.socket === socket, id == current else { throw .staleConnection }
        modeFields = answer?.modeFields
        Self.logger.info("agent pane transport open connection=\(id, privacy: .public) localApp=\(self.localAppToken != nil, privacy: .public)")
        return id
    }

    /// Sends the page's frames in order, after every earlier send. A refused frame is not sent; a
    /// refused request is answered with a JSON-RPC error frame. Returns the first error, if any.
    @discardableResult
    public func send(connection id: Int, frames: [String]) async -> AgentPaneTransportError? {
        let turn = reserveSend()
        await turn.granted()
        defer { releaseSend() }
        return await run(connection: id, frames: frames)
    }

    /// The bridge's entry: queued in arrival order (the turn is reserved before this returns, so a
    /// later frame never overtakes it). The frame's work runs off the main thread.
    public func submit(connection id: Int, frames: [String], reply: @escaping @MainActor (AgentPaneTransportError?) -> Void) {
        let turn = reserveSend()
        // task-owner: one queued page send; its turn was reserved above, its reply goes to the page
        Task { [weak self] in
            await turn.granted()
            guard let self else { return reply(.closed) }
            let result = await self.run(connection: id, frames: frames)
            self.releaseSend()
            reply(result)
        }
    }

    private func run(connection id: Int, frames: [String]) async -> AgentPaneTransportError? {
        var firstError: AgentPaneTransportError?
        for frame in frames {
            switch await step(connection: id, frame: frame) {
            case .sent: continue
            case .refused(let error): firstError = firstError ?? error
            case .stop(let error): return firstError ?? error
            }
        }
        return firstError
    }

    enum Step { case sent, refused(AgentPaneTransportError), stop(AgentPaneTransportError) }

    /// A queued send's place in line.
    @MainActor final class SendTurn {
        private var isGranted = false
        private var continuation: CheckedContinuation<Void, Never>?
        func granted() async {
            guard !isGranted else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func grant() {
            isGranted = true
            continuation?.resume()
            continuation = nil
        }
    }

    private var sendBusy = false
    private var sendQueue: [SendTurn] = []

    /// Sends run one after another, in the order they were reserved.
    private func reserveSend() -> SendTurn {
        let turn = SendTurn()
        if sendBusy { sendQueue.append(turn) } else { sendBusy = true; turn.grant() }
        return turn
    }

    private func releaseSend() {
        if sendQueue.isEmpty { sendBusy = false } else { sendQueue.removeFirst().grant() }
    }

    // MARK: One page frame

    /// What the off-main work needs from the main actor: small values and thread-safe handles.
    nonisolated struct Snapshot: Sendable {
        var isFirst: Bool
        var localAppToken: String?
        var modeFields: Set<String>?
        var sessions: AcpmuxPaneSessions
        var options: AcpmuxPermissionOptions
    }

    /// What the main actor learns about a frame that needs its state: small values, never the frame.
    nonisolated struct Facts: Sendable {
        var method: String?
        var pageID: String?
        /// The gesture ticket the frame carried (already stripped from it), and whether its `_meta`
        /// held anything else (R1).
        var ticket: String?
        var otherMeta = false
        var pick: AgentPaneGesturePick?
        var sessionId: String?
        var needsGesture = false
        var needsPathCheck = false
        var setting: Setting?
        /// An attach of a session that is not the pane's yet (only a gesture brings it in).
        var attachSession: String?

        /// No main-actor state decides this frame: it is checked, encoded and sent in one step.
        var free: Bool {
            ticket == nil && !needsGesture && !needsPathCheck && setting == nil && attachSession == nil
        }
    }

    /// A mode or config option the frame sets (R2, P2), with the sheet's text.
    nonisolated struct Setting: Sendable {
        var sessionId: String?
        var configId: String
        var value: String?
        var asked: AgentPaneModeConfirmation
    }

    /// The decided frame. It stays off the main actor: only its step reads or changes it, one stage
    /// after another (the send line runs one frame at a time), never the main actor.
    nonisolated final class FrameBox: @unchecked Sendable {
        var object: [String: Any]
        init(_ object: [String: Any]) { self.object = object }
    }

    nonisolated enum Analysis: Sendable {
        /// Refused before the main actor (a ticket in it, if any, is to be spent).
        case refuse(AcpmuxPaneMethods.Decision, spend: String?)
        /// Sent already (a free frame), or the socket's error.
        case sent(AgentPaneTransportError?)
        /// The main actor decides.
        case decide(Facts, FrameBox)
    }

    /// One frame, in order. Off the main thread: the duplicate check, the one parse every rule
    /// reads, the rules that need no main-actor state, the re-encode and the send. On the main
    /// actor, with small values only: the gesture record, the sheets and the pane's sessions.
    private func step(connection id: Int, frame text: String) async -> Step {
        guard id == current, let socket, let ids = requestIds else { return .stop(.staleConnection) }
        let snapshot = Snapshot(isFirst: !sentFirst, localAppToken: localAppToken, modeFields: modeFields,
                                sessions: sessions, options: permissionOptions)
        let analysis = await Self.analyze(text, snapshot, socket: socket, ids: ids)
        if snapshot.isFirst, case .sent(nil) = analysis {
            sentFirst = true
            localAppToken = nil
        }
        guard id == current, self.socket === socket else { return .stop(.staleConnection) }
        let facts: Facts
        let box: FrameBox
        switch analysis {
        case .sent(nil):
            return .sent
        case .sent(let error?):
            return .stop(error)
        case .refuse(let decision, let spend):
            // B2: a ticket in a refused frame is spent all the same.
            if let spend { _ = gestures.redeem(spend, connection: id, pick: nil) }
            return refuse(decision, socket: socket)
        case .decide(let found, let frame):
            facts = found
            box = frame
        }
        var rootRequested = false
        if facts.needsPathCheck {
            let scope = AcpmuxPathPolicy.Scope(roots: roots() + addedRoots, gestureRoots: gestureRoots(), fillCwd: primaryRoot())
            let result = await Self.checkPaths(box, scope: scope)
            guard id == current, self.socket === socket else { return .stop(.staleConnection) }
            switch result {
            case .success(let gestureRootsUsed):
                // A folder of the new tab page's scan counts only when the user picked it.
                if !gestureRootsUsed.isEmpty {
                    guard gestures.consume() else {
                        return refuse(.refuse(.pathOutsideRoots, method: facts.method, requestID: facts.pageID), socket: socket)
                    }
                    addedRoots += gestureRootsUsed.filter { !addedRoots.contains($0) }
                }
            case .failure(let refusal):
                if refusal.error == .pathOutsideRoots, let folder = refusal.outsidePath { rootRequested = offerRoot(folder) }
                return refuse(.refuse(refusal.error, method: refusal.method, requestID: refusal.requestID), socket: socket,
                              rootRequested: rootRequested)
            }
        }
        // The gesture rule: a ticket for its exact pick (R1: nothing else in `_meta`), else a live gesture.
        if !snapshot.isFirst {
            let granted: Bool
            if let ticket = facts.ticket {
                if facts.otherMeta {
                    _ = gestures.redeem(ticket, connection: id, pick: nil)
                    return refuse(.refuse(.intentInvalid, method: facts.method, requestID: facts.pageID), socket: socket)
                }
                // B2: only set_mode and set_config_option redeem a ticket, for their exact pick, into
                // a session of this pane. A ticket is spent even when it does not match.
                let redeemed = gestures.redeem(ticket, connection: id, pick: facts.pick)
                granted = redeemed && AgentPaneGestureIntent.methods[facts.method ?? ""] != nil
                    && facts.sessionId.map(sessions.contains) == true
            } else {
                granted = !facts.needsGesture || gestures.consume()
            }
            if !granted { return refuse(.refuse(.gestureRequired, method: facts.method, requestID: facts.pageID), socket: socket) }
        }
        // R2 and P2: a mode, or a config option that is not free, needs the user's native
        // confirmation unless the daemon says that the value keeps the session asking.
        if let setting = facts.setting {
            let answer = await webModes(setting.sessionId, setting.configId, setting.value)
            guard id == current, self.socket === socket else { return .stop(.staleConnection) }
            let asks = answer?.freeConfigIds.contains(setting.configId) == true || answer?.asks == true
            if !asks {
                let confirmed = await confirm(setting.asked)
                guard id == current, self.socket === socket else { return .stop(.staleConnection) }
                if !confirmed { return refuse(.refuse(.modeNotConfirmed, method: facts.method, requestID: facts.pageID), socket: socket) }
            }
        }
        // The daemon sees only relay-owned ids; a page id is used by one request at a time.
        var relayID: Int?
        if let pageID = facts.pageID {
            guard let next = ids.begin(pageID: pageID, method: facts.method ?? "") else { return refuseInFlight() }
            relayID = next
        }
        if snapshot.isFirst {
            sentFirst = true
            localAppToken = nil
        } else {
            noteSent(facts, relayID: relayID)
            // The switch's queued prompt goes out: the switch has ended, its tickets with it.
            if facts.method == "session/prompt" { gestures.clearTickets() }
        }
        if let error = await Self.encodeAndSend(box, relayID: relayID, socket: socket) {
            if let relayID { ids.cancel(relayID) }
            if error == .outboundOverflow { socket.close(code: 1008, reason: "outbound overflow", error: error) }
            return .stop(error)
        }
        return .sent
    }

    /// The off-main part of a frame's check (see ``step(connection:frame:)``).
    @concurrent private nonisolated static func analyze(_ text: String, _ snapshot: Snapshot, socket: AcpmuxPaneSocket,
                                                         ids: AcpmuxRequestIds) async -> Analysis {
        let object: [String: Any]
        switch AcpmuxPaneMethods.decideFrame(text, isFirst: snapshot.isFirst) {
        case .failure(let refusal): return .refuse(refusal.decision, spend: nil)
        case .success(let decided): object = decided
        }
        let method = object["method"] as? String
        let pageID = object["id"].flatMap(AcpmuxPaneMethods.rawID)
        let params = object["params"] as? [String: Any] ?? [:]
        let carried = (params["_meta"] as? [String: Any])?[AcpmuxPaneMethods.gestureTicketKey] as? String
        if !snapshot.isFirst, let refusal = sessionRefusal(object, sessions: snapshot.sessions) {
            return .refuse(refusal, spend: carried)
        }
        // P1: the method's known params, and no daemon mode field outside set_mode and set_config_option.
        if AcpmuxPaneMethods.breaksParamsRule(object, modeFields: snapshot.modeFields) {
            return .refuse(.refuse(.intentInvalid, method: method, requestID: pageID), spend: carried)
        }
        // A prompt block's own _meta never reaches the harness.
        var frame = AcpmuxPaneMethods.strippingPromptMeta(object) ?? object
        var facts = Facts(method: method, pageID: pageID)
        if !snapshot.isFirst {
            let (stripped, ticket, otherMeta) = AcpmuxPaneMethods.takeGestureTicket(frame)
            frame = stripped
            facts.ticket = ticket
            facts.otherMeta = otherMeta
            if ticket != nil {
                facts.pick = AgentPaneGesturePick(method: method, params: params)
                facts.sessionId = params["sessionId"] as? String
            }
            facts.needsGesture = AcpmuxPaneMethods.needsGesture(frame, options: snapshot.options)
            facts.needsPathCheck = AcpmuxPathPolicy.needsCheck(frame)
            if method == "_acpmux/attach", let session = params["sessionId"] as? String, !snapshot.sessions.contains(session) {
                facts.attachSession = session
            }
        }
        if let requested = AcpmuxPaneMethods.requestedSetting(frame) {
            let value = requested.value ?? configValueText(frame)
            facts.setting = Setting(sessionId: requested.sessionId, configId: requested.configId, value: requested.value,
                                    asked: requested.configId == "mode" ? .mode(value) : .option(id: requested.configId, value: value))
        }
        // The LocalApp token goes into the first frame after every rule read the page's own frame.
        if snapshot.isFirst, let token = snapshot.localAppToken { frame = AcpmuxPaneMethods.withLocalAppToken(frame, token) }
        let box = FrameBox(frame)
        guard facts.free else { return .decide(facts, box) }
        // Free: nothing on the main actor decides it, so it goes out from here, in the same order.
        var relayID: Int?
        if let pageID {
            guard let next = ids.begin(pageID: pageID, method: method ?? "") else { return .refuse(.refuse(.requestIdInFlight, method: nil, requestID: nil), spend: nil) }
            relayID = next
        }
        if !snapshot.isFirst, let method, AcpmuxPaneSessions.starting.contains(method) {
            snapshot.sessions.sent(method: method, id: pageID, params: params)
        }
        let error = sendNow(box, relayID: relayID, socket: socket)
        if error != nil, let relayID { ids.cancel(relayID) }
        if error == .outboundOverflow { socket.close(code: 1008, reason: "outbound overflow", error: error) }
        return .sent(error)
    }

    /// The folder rule on the decided frame (the disk is read here, off the main thread). The
    /// checked frame (canonical paths, a filled cwd) replaces the box's object.
    @concurrent private nonisolated static func checkPaths(_ box: FrameBox, scope: AcpmuxPathPolicy.Scope) async
        -> Result<[String], AcpmuxPathPolicy.Refusal> {
        guard let text = AcpmuxRequestIds.encode(box.object) else {
            return .failure(AcpmuxPathPolicy.Refusal(error: .invalidFrame, requestID: nil, method: nil))
        }
        switch AcpmuxPathPolicy.checkNow(text, scope: scope) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let checked):
            guard let object = (try? JSONSerialization.jsonObject(with: Data(checked.text.utf8))) as? [String: Any] else {
                return .failure(AcpmuxPathPolicy.Refusal(error: .invalidFrame, requestID: nil, method: nil))
            }
            box.object = object
            return .success(checked.gestureRootsUsed)
        }
    }

    @concurrent private nonisolated static func encodeAndSend(_ box: FrameBox, relayID: Int?, socket: AcpmuxPaneSocket) async
        -> AgentPaneTransportError? {
        sendNow(box, relayID: relayID, socket: socket)
    }

    /// The fresh serialization of the decided frame, with the relay id, to the socket; never the
    /// page's bytes.
    private nonisolated static func sendNow(_ box: FrameBox, relayID: Int?, socket: AcpmuxPaneSocket) -> AgentPaneTransportError? {
        var object = box.object
        if let relayID { object["id"] = relayID }
        guard let text = AcpmuxRequestIds.encode(object) else { return .invalidFrame }
        return socket.send(text)
    }

    /// A refused frame: answered when it is a request, the socket closed when it was the first.
    private func refuse(_ decision: AcpmuxPaneMethods.Decision, socket: AcpmuxPaneSocket, rootRequested: Bool = false) -> Step {
        guard case .refuse(let error, let method, let requestID) = decision else { return .stop(.invalidFrame) }
        if error == .requestIdInFlight { return refuseInFlight() }
        Self.logger.error("agent pane transport refused frame error=\(error.rawValue, privacy: .public) method=\(method ?? "-", privacy: .public)")
        if error == .firstFrameNotInitialize {
            socket.close(code: 1008, reason: "first frame", error: error)
            return .stop(error)
        }
        if let requestID {
            socket.inject(AcpmuxPaneMethods.refusal(requestID: requestID, error: error, method: method, rootRequested: rootRequested))
        }
        return .refused(error)
    }

    /// No answer: the page's earlier request with this id still waits for its own.
    private func refuseInFlight() -> Step {
        Self.logger.error("agent pane transport refused frame error=\(AgentPaneTransportError.requestIdInFlight.rawValue, privacy: .public)")
        return .refused(.requestIdInFlight)
    }

    /// A config option's value as text, for the sheet (a value that is not a string).
    private nonisolated static func configValueText(_ object: [String: Any]?) -> String {
        let value = (object?["params"] as? [String: Any])?["value"]
        guard let value else { return "" }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }

    /// Asks the user to confirm a mode that does not ask (the native sheet); false without one.
    private func confirm(_ asked: AgentPaneModeConfirmation) async -> Bool {
        guard let requestModeConfirmation else { return false }
        let gate = confirmationGate
        guard gate.open() else { return false }
        defer { gate.close() }
        return await withCheckedContinuation { continuation in
            requestModeConfirmation(asked) { continuation.resume(returning: $0) }
        }
    }

    /// The refusal of a session-scoped frame for a session that is not this pane's.
    private nonisolated static func sessionRefusal(_ object: [String: Any], sessions: AcpmuxPaneSessions) -> AcpmuxPaneMethods.Decision? {
        guard let method = object["method"] as? String, AcpmuxPaneMethods.sessionScoped.contains(method) else { return nil }
        let session = (object["params"] as? [String: Any])?["sessionId"] as? String
        guard let session, sessions.contains(session) else {
            return .refuse(.sessionNotInPane, method: method, requestID: object["id"].flatMap(AcpmuxPaneMethods.rawID))
        }
        return nil
    }

    /// Records what a sent frame starts, or opens by the user's gesture. An attach alone adds
    /// nothing: only an attach the user made (a click in the session list) brings a session in.
    private func noteSent(_ facts: Facts, relayID: Int?) {
        if let session = facts.attachSession, !sessions.contains(session), gestures.consume() {
            sessions.add(session)
        }
        if let method = facts.method, AcpmuxPaneSessions.starting.contains(method) {
            sessions.sent(method: method, id: facts.pageID, params: [:])
        }
    }

    /// `transport.gesture`: reserves the current gesture for one pick sent later on this connection.
    public func reserveGesture(_ intent: AgentPaneGestureIntent) -> String? {
        guard socket != nil else { return nil }
        return gestures.reserve(connection: current, intent: intent)
    }

    /// Offers the user to add `folder` as a root: only after a real gesture (which the offer uses),
    /// one sheet at a time. True when the sheet is shown.
    private func offerRoot(_ folder: String) -> Bool {
        guard !askingRoot, let requestRoot, gestures.consume() else { return false }
        askingRoot = true
        requestRoot(folder) { [weak self] add in
            guard let self else { return }
            self.askingRoot = false
            if add, !self.addedRoots.contains(folder) { self.addedRoots.append(folder) }
        }
        return true
    }

    /// Closes the connection if it is the current one.
    public func close(connection id: Int) {
        guard id == current, let socket else { return }
        socket.close(code: 1000, reason: "", error: nil)
        self.socket = nil
        localAppToken = nil
    }

    private func arrived(_ id: Int) {
        guard id == current, socket != nil else { return }
        pacer.schedule { [weak self] in self?.flush() ?? AgentPaneFlush(delivered: false, more: false) }
    }

    /// Delivers one batch, and says whether it made a call and whether more is waiting.
    @discardableResult
    func flush() -> AgentPaneFlush {
        guard let socket else { return AgentPaneFlush(delivered: false, more: false) }
        let batch = socket.take(maximumFrames: limits.maximumFramesPerFlush, maximumBytes: limits.maximumBytesPerFlush)
        guard !batch.frames.isEmpty || batch.closed != nil else { return AgentPaneFlush(delivered: false, more: batch.more) }
        flushes += 1
        let event = AgentPaneTransportEvent(connection: current, frames: batch.frames, closed: batch.closed)
        if batch.closed != nil {
            self.socket = nil
            localAppToken = nil
            Self.logger.info("agent pane transport closed connection=\(self.current, privacy: .public) code=\(batch.closed?.code ?? 0, privacy: .public) error=\(batch.closed?.error?.rawValue ?? "-", privacy: .public)")
        }
        let more = batch.more && self.socket != nil
        guard let deliver else { return AgentPaneFlush(delivered: false, more: more) }
        deliveries += 1
        let delivery = deliveries
        deliver(event) { [weak self] in
            guard let self, self.deliveries == delivery else { return }
            self.pacer.delivered()
        }
        if batch.closed != nil { pacer.reset() }
        return AgentPaneFlush(delivered: batch.closed == nil, more: more)
    }
}

/// The URLSession WebSocket behind ``AgentPaneTransport``. Its callbacks run on its own serial
/// queue; the queues are guarded by one Mutex that is never held across IO.
nonisolated final class AcpmuxPaneSocket: NSObject, URLSessionWebSocketDelegate, Sendable {
    struct Batch {
        var frames: [String]
        var closed: AgentPaneTransportClose?
        var more: Bool
    }

    private struct State {
        var session: URLSession?
        var task: URLSessionWebSocketTask?
        var opening: CheckedContinuation<Void, any Error>?
        var opened = false
        var inbox: [String] = []
        var inboxBytes = 0
        var signaled = false
        var outstanding = 0
        var outstandingBytes = 0
        var closed: AgentPaneTransportClose?
        var closeDelivered = false
    }

    private let request: URLRequest
    private let limits: AgentPaneTransport.Limits
    private let options: AcpmuxPermissionOptions
    private let sessions: AcpmuxPaneSessions
    private let ids: AcpmuxRequestIds
    private let signal: @Sendable () -> Void
    private let state = Mutex(State())

    init(request: URLRequest, limits: AgentPaneTransport.Limits, options: AcpmuxPermissionOptions,
         sessions: AcpmuxPaneSessions, ids: AcpmuxRequestIds, signal: @escaping @Sendable () -> Void) {
        self.request = request
        self.limits = limits
        self.options = options
        self.sessions = sessions
        self.ids = ids
        self.signal = signal
    }

    func start(timeout: TimeInterval) async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        var request = request
        request.timeoutInterval = timeout
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = AcpmuxPaneMethods.maximumFrameBytes
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let cancelled = state.withLock { state -> Bool in
                guard state.closed == nil else { return true }
                state.session = session
                state.task = task
                state.opening = continuation
                return false
            }
            if cancelled {
                session.invalidateAndCancel()
                continuation.resume(throwing: AgentPaneTransportError.closed)
            } else {
                task.resume()
            }
        }
    }

    // MARK: Inbound

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)): self.arrived(text)
            case .success(.data(let data)): self.arrived(String(decoding: data, as: UTF8.self))
            case .success: break
            case .failure: return self.finish(code: 1006, reason: "", error: nil)
            }
            self.receive(task)
        }
    }

    /// A frame for the page: from the daemon (its ids mapped back, unknown replies dropped), or
    /// the relay's own answer to a refused request (`fromDaemon` false).
    private func arrived(_ received: String, fromDaemon: Bool = true) {
        guard let text = fromDaemon ? ids.toPage(received) : received else { return }
        options.observe(text)
        sessions.observe(text)
        let bytes = text.utf8.count
        let (wake, overflow) = state.withLock { state -> (Bool, Bool) in
            guard state.closed == nil else { return (false, false) }
            if state.inbox.count >= limits.maximumQueuedFrames || state.inboxBytes + bytes > limits.maximumQueuedBytes {
                return (false, true)
            }
            state.inbox.append(text)
            state.inboxBytes += bytes
            guard !state.signaled else { return (false, false) }
            state.signaled = true
            return (true, false)
        }
        if overflow { close(code: 1008, reason: "inbound overflow", error: .inboundOverflow) }
        if wake { signal() }
    }

    var queuedFrames: Int { state.withLock { $0.inbox.count } }

    /// Queues a frame the host made (a refusal) as if the daemon had sent it.
    func inject(_ text: String) { arrived(text, fromDaemon: false) }

    /// Up to `maximumFrames` frames and `maximumBytes` bytes (at least one frame), and the close
    /// once every frame before it was taken. Dropped queues on an overflow close are not kept.
    func take(maximumFrames: Int, maximumBytes: Int) -> Batch {
        state.withLock { state in
            var count = 0
            var bytes = 0
            while count < min(maximumFrames, state.inbox.count) {
                let size = state.inbox[count].utf8.count
                if count > 0, bytes + size > maximumBytes { break }
                bytes += size
                count += 1
            }
            let frames = Array(state.inbox.prefix(count))
            state.inbox.removeFirst(count)
            state.inboxBytes -= bytes
            var closed: AgentPaneTransportClose?
            if state.inbox.isEmpty, let close = state.closed, !state.closeDelivered {
                state.closeDelivered = true
                closed = close
            }
            let more = !state.inbox.isEmpty
            if !more { state.signaled = false }
            return Batch(frames: frames, closed: closed, more: more)
        }
    }

    // MARK: Outbound

    /// Nil when the frame was handed to the socket.
    func send(_ text: String) -> AgentPaneTransportError? {
        let bytes = text.utf8.count
        let outcome = state.withLock { state -> Result<URLSessionWebSocketTask, AgentPaneTransportError> in
            guard state.closed == nil, let task = state.task, state.opened else { return .failure(.closed) }
            guard state.outstanding < limits.maximumOutstandingSends,
                  state.outstandingBytes + bytes <= limits.maximumOutstandingBytes else { return .failure(.outboundOverflow) }
            state.outstanding += 1
            state.outstandingBytes += bytes
            return .success(task)
        }
        switch outcome {
        case .failure(let error): return error
        case .success(let task):
            task.send(.string(text)) { [weak self] error in
                guard let self else { return }
                self.state.withLock { state in
                    state.outstanding -= 1
                    state.outstandingBytes -= bytes
                }
                if error != nil { self.finish(code: 1006, reason: "", error: nil) }
            }
            return nil
        }
    }

    // MARK: Close

    /// Closes the socket (the host's decision): queued inbound frames are dropped on an error.
    func close(code: Int, reason: String, error: AgentPaneTransportError?) {
        let (task, session, wake) = state.withLock { state -> (URLSessionWebSocketTask?, URLSession?, Bool) in
            guard state.closed == nil else { return (nil, nil, false) }
            state.closed = AgentPaneTransportClose(code: code, reason: reason, error: error)
            if error != nil {
                state.inbox.removeAll()
                state.inboxBytes = 0
            }
            let wake = !state.signaled
            state.signaled = true
            return (state.task, state.session, wake)
        }
        task?.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: Data(reason.utf8))
        session?.finishTasksAndInvalidate()
        if wake { signal() }
    }

    /// The socket ended on its own (the daemon closed it, or IO failed).
    private func finish(code: Int, reason: String, error: AgentPaneTransportError?) {
        let (opening, session, wake) = state.withLock { state -> (CheckedContinuation<Void, any Error>?, URLSession?, Bool) in
            let opening = state.opening
            state.opening = nil
            guard state.closed == nil else { return (opening, nil, false) }
            state.closed = AgentPaneTransportClose(code: code, reason: reason, error: error)
            let wake = !state.signaled
            state.signaled = true
            return (opening, state.session, wake)
        }
        opening?.resume(throwing: AgentPaneTransportError.connectFailed)
        session?.finishTasksAndInvalidate()
        if wake { signal() }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol subprotocol: String?) {
        let opening = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            state.opened = true
            let opening = state.opening
            state.opening = nil
            return opening
        }
        receive(webSocketTask)
        opening?.resume()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(code: closeCode.rawValue, reason: reason.map { String(decoding: $0, as: UTF8.self) } ?? "", error: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(code: 1006, reason: "", error: nil)
    }
}
