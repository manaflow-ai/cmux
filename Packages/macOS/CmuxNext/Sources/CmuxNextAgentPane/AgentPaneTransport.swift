public import Foundation
import os
import Synchronization

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

    nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.transport")
    public let limits: Limits
    /// Gets each push for the page (the view sends it through the bridge) and a completion to call
    /// once the page has run it (it paces the next push).
    public var deliver: (@MainActor (AgentPaneTransportEvent, _ done: @escaping @MainActor @Sendable () -> Void) -> Void)?
    /// Counts pushes, so a late completion of a previous connection's push is ignored.
    private var deliveries = 0
    private var pacerStorage: any AgentPaneTransportPacer
    public var pacer: any AgentPaneTransportPacer {
        get { pacerStorage }
        set {
            let previous = pacerStorage
            pacerStorage = newValue
            // An AppKit view can replace the default pacer from a synchronous callback. Keep
            // the old actor-isolated pacer alive until its release runs on the main actor.
            Task { @MainActor in
                withExtendedLifetime(previous) {}
            }
        }
    }
    var socket: AcpmuxPaneSocket?
    var current = 0
    /// Held from `open` until the first frame is sent, then dropped.
    var localAppToken: String?
    var sentFirst = false
    /// The send line (``submit(connection:frames:reply:)``), drained in order by one task at a time.
    var pending: [PendingSend] = []
    var draining = false
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
    /// The workspace's agent-home folder: a root once it exists, and the cwd of a `session/new`
    /// that names none when there is no ``primaryRoot`` (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE).
    public var agentHome: @MainActor () -> AgentHomeFill? = { nil }
    /// The user's home folder: never a root or a filled cwd unless the user added it
    /// (``addedRoots``), so an inherited or default `~` never opens the whole home folder.
    public var homeFolder: String? = NSHomeDirectory()
    /// Folders the user added or picked by a gesture: roots from then on.
    public internal(set) var addedRoots: [String] = []
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
    /// acpmux's Enable harness prompt for `id` in `folder` (`_acpmux/harness_enable` without
    /// sha256, over the unix socket); nil when the daemon cannot give one (refused, not found).
    public var harnessEnablePrompt: @MainActor (_ folder: String, _ id: String) async -> AgentPaneHarnessEnablePrompt? = { _, _ in nil }
    /// Shows the native Enable harness sheet for `prompt`; Cancel answers false.
    public var requestHarnessEnable: (@MainActor (_ prompt: AgentPaneHarnessEnablePrompt, _ answer: @escaping @MainActor (Bool) -> Void) -> Void)?
    /// The current socket's request ids (relay-owned, mapped back on the reply).
    var requestIds: AcpmuxRequestIds?
    private var socketPath: String?

    /// Pushes and flushes so far (tests and the bench read them).
    public private(set) var flushes = 0

    public init(limits: Limits = Limits(), pacer: (any AgentPaneTransportPacer)? = nil,
                gestures: AgentPaneUserGestures = AgentPaneUserGestures()) {
        self.limits = limits
        self.gestures = gestures
        self.pacerStorage = pacer ?? AgentPaneNextTurnPacer()
        webModes = { [weak self] session, configId, value in
            guard let path = self?.socketPath else { return nil }
            return await AcpmuxStatusClient.webModes(socketPath: path, sessionId: session, configId: configId, value: value)
        }
        harnessEnablePrompt = { [weak self] folder, id in
            guard let path = self?.socketPath else { return nil }
            return await AcpmuxStatusClient.harnessEnablePrompt(socketPath: path, folder: folder, id: id)
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
            // task-owner: one wake for the pacer; arrived(_:) ignores a stale connection
            Task { @MainActor [weak self] in self?.arrived(id) }
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
        await withCheckedContinuation { continuation in
            submit(connection: id, frames: frames) { continuation.resume(returning: $0) }
        }
    }

    /// The bridge's entry: the frames join the send line in arrival order (they are in line before
    /// this returns, so a later frame never overtakes them). Their work runs off the main thread.
    public func submit(connection id: Int, frames: [String], reply: @escaping @MainActor (AgentPaneTransportError?) -> Void) {
        pending.append(PendingSend(connection: id, frames: frames, reply: reply))
        guard !draining else { return }
        draining = true
        // task-owner: the send line's one drain; it ends when the line is empty
        Task { [weak self] in await self?.drain() }
    }

    nonisolated enum Step: Sendable { case sent, refused(AgentPaneTransportError), stop(AgentPaneTransportError) }

    /// One page send in line: its frames still to go, its first error, and where its result goes.
    final class PendingSend {
        let connection: Int
        var frames: [String]
        var firstError: AgentPaneTransportError?
        let reply: @MainActor (AgentPaneTransportError?) -> Void

        init(connection: Int, frames: [String], reply: @escaping @MainActor (AgentPaneTransportError?) -> Void) {
            self.connection = connection
            self.frames = frames
            self.reply = reply
        }
    }

    /// `transport.gesture`: reserves the current gesture for one pick sent later on this connection.
    public func reserveGesture(_ intent: AgentPaneGestureIntent) -> String? {
        guard socket != nil else { return nil }
        return gestures.reserve(connection: current, intent: intent)
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
