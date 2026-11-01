public import Foundation
import CmuxNextPages
import os
import CmuxNextCompat

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
    /// Runs right before anything reaches the page: a push here, a script call or a picture
    /// (``AgentPaneView/callPageScript(_:arguments:)``, ``AgentPaneView/pageSnapshot()``). A hidden page
    /// that froze (the app's hibernation) thaws first, so the work runs now instead of waiting on a
    /// page that runs no script (a push's completion paces the next one).
    public var beforePageWork: (@MainActor () -> Void)?
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
    /// Host-owned requests (for example the trust record after a native folder picker). They share
    /// the page send line so initialization and person proof always precede them.
    var pendingHost: [PendingHostSend] = []
    var awaitingHost: [Int: PendingHostSend] = [:]
    var personProofID: Int?
    var pendingTrustFolders: [AgentPanePromptJournal.PendingTrust] = []
    var trustDaemon: String?
    var draining = false
    /// Waiting on the send line to drain (``lineDrained(within:)``).
    var drainWaiters: [CheckedContinuation<Void, Never>] = []
    /// The user's gestures in this pane; a granting frame consumes one.
    public let gestures: AgentPaneUserGestures
    /// This Mac's acpmux socket from the last handshake (the agent CLI card's update and restart).
    var acpmuxSocket: String?
    /// The acpmux that serves ``acpmuxSocket``, for a background process's terminal (``AgentPaneProcessViewer``).
    var acpmuxExecutable: URL?
    /// The permission options the daemon sent, to tell an allow from a deny.
    public let permissionOptions = AcpmuxPermissionOptions()
    /// The sessions this pane started or shows.
    public let sessions = AcpmuxPaneSessions()
    /// Each shown prompt's decision nonce and daemon run, for a relayed allow's proof (cx-0q7o).
    public let decisions = AcpmuxDecisionContexts()
    /// The private isolated-world snapshot for the current physical Return. The page can only
    /// request a ticket matching it; it cannot create or replace this evidence.
    struct QuestionKeyCredit {
        let target: PageQuestionKeyTarget
        let intent: AgentPaneGestureIntent
        let context: AcpmuxDecisionContexts.Context
        let connection: Int
        let witness: UUID
        let redeem: @MainActor () async -> Bool
    }
    var questionKeyCredit: QuestionKeyCredit?
    private var questionKeyTickets: [String: QuestionKeyCredit] = [:]
    /// Captured Return requests not yet answered to the page, including admission races.
    var capturedQuestionKeyReplies: [String: CapturedQuestionKeyReply] = [:]
    /// The keyed restart the chat's machine offers, when it runs on another machine.
    private(set) var remoteApprovals: AgentPaneRemoteApprovals?
    /// The canonical host key of the current remote chat, when its tab record supplied one.
    private(set) var remoteHostID: String?
    /// The current connection is a chat on another machine (``RemoteAcpmuxWire``): its folders are
    /// that machine's, so this Mac's folder rule does not read them (that machine's acpmux checks
    /// its own folder trust, cx-k21v).
    private(set) var remoteWire = false
    /// The current remote chat's host reader, installed from the same wire that carries its ACP.
    var remoteImageLoader: (@Sendable (String) async throws -> Data)?
    /// Cloud repository actions use the current machine/attachment daemon frame connection.
    public var cloudRepository: (@Sendable (String, [String: any Sendable], Duration?) async throws -> Data)?
    /// A `session/new` took the person's send gesture: the first `session/prompt` on that
    /// connection goes with it within ``startCreditLifetime``. On another machine the start needs
    /// that gesture; on this Mac it needs none but carries one it finds.
    var startCredit = AgentPaneGestureCredit()
    /// Starts and opens of a chat here that may still replace an unstarted new chat: while any is
    /// out, a Sandboxed send (`sandbox.run`) is refused (``AcpmuxPaneReplacements``).
    public let replacements = AcpmuxPaneReplacements()
    /// A trusting `acp.trust.set` on a remote wire took the person's Trust click: it also allows
    /// one `session/new` on that connection (the start the trust question held, cx-1bhjj).
    var remoteTrustCredit = AgentPaneGestureCredit()
    /// A folder pick took the person's gesture (``grantPicked(_:)``): the next `session/new` on this
    /// Mac on that connection carries it as its own (``startCredit``). Nothing else spends it.
    var pickCredit = AgentPaneGestureCredit()
    /// Home folders of the chat's machine the person chose by Use Home Folder (cx-1bhjj): only
    /// these may be trusted or started in there. Never this Mac's roots (``addedRoots``).
    public internal(set) var remoteHomeChosen: Set<String> = []
    /// How long a start's gesture waits for its first prompt (the start may take 75 s).
    static let startCreditLifetime: TimeInterval = 120
    /// Told when an allow went to another daemon run without the person's proof: that daemon
    /// holds no key of this app for that run, so it refuses the allow.
    public var onRemoteApprovalsOff: (@MainActor (AgentPaneRemoteApprovals?) -> Void)?
    /// Told when a peer of this Mac's daemon did not count an allow signed by this Mac
    /// (peer-route approvals, ``AcpmuxMacApprover``): it has not enrolled this Mac, or the allow
    /// was not a one-time allow. nil: a later answer counted, and what was said no longer holds.
    public var onPeerApprovalsOff: (@MainActor (AgentPanePeerApprovals?) -> Void)?
    /// Called after daemon frames update the native pending-question projection.
    var onQuestionStateChanged: (@MainActor () -> Void)?
    /// This app's approver key and Enroll this Mac (``AgentPanePeerApprover``), from the app's pane
    /// factory; nil: a peer's prompt gets no signed allow and the notice offers no Enroll.
    public var peerApprover: AgentPanePeerApprover?
    /// The pane's own roots (``AcpmuxPathPolicy/Scope/roots``), asked at each frame.
    public var roots: @MainActor () -> [String] = { [] }
    /// Folders that are roots only when the user picks one by a gesture (the new tab page's scan).
    public var gestureRoots: @MainActor () -> [String] = { [] }
    /// The pane's workspace root, the cwd of a `session/new` that names none.
    public var primaryRoot: @MainActor () -> String? = { nil }
    /// The workspace's agent-home folder: a root once it exists, and the cwd of a `session/new`
    /// that names none when there is no ``primaryRoot`` (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE).
    public var agentHome: @MainActor () -> AgentHomeFill? = { nil }
    /// The pane's cmux workspace key on this Mac's daemon, stamped on each local `session/new`
    /// (``AcpmuxPathPolicy/Scope/workspaceID``); nil for none or a workspace of another machine.
    public var workspaceID: @MainActor () -> String? = { nil }
    /// The user's home folder: never a root or a filled cwd unless the user added it
    /// (``addedRoots``), so an inherited or default `~` never opens the whole home folder.
    public var homeFolder: String? = NSHomeDirectory()
    /// Folders the user added or picked by a gesture: roots from then on.
    public internal(set) var addedRoots: [String] = []

    /// Makes `folder` (canonical) a root: the user's answer to a folder question (`workspace.useFolder`).
    func grant(_ folder: String) {
        if !addedRoots.contains(folder) { addedRoots.append(folder) }
    }

    /// `folder` the person's gesture picked (`workspace.useFolder`): made a root, and the gesture it
    /// spent goes on to the chat that starts there (``pickCredit``), then its first prompt. The New
    /// Tab page asks for the folder in the same turn as the Send, so the pick took the Send's only
    /// gesture and the chat's first prompt was refused ("Not sent. Press Retry to send it.").
    func grantPicked(_ folder: String, carryGesture: Bool = true, trust: Bool = true) async {
        grant(folder)
        if carryGesture, socket != nil { pickCredit.give(connection: current, at: gestures.uptime) }
        if trust { await trustPicked(folder) }
    }
    /// Whether the daemon's asking table (acpmux `web_modes.rs`) lists `mode` for the session's
    /// family: true or false, nil when it cannot tell (which needs the confirmation, fail closed).
    /// The host's default asks the daemon over its unix socket (`_acpmux/web_modes`).
    public var webModes: @MainActor (_ sessionId: String?, _ configId: String?, _ value: String?) async -> AcpmuxWebModes? = { _, _, _ in nil }
    /// The daemon's mode fields for this connection (asked at open): an extra deny inside the
    /// known-params rule (``AcpmuxPaneMethods/knownParams``), which applies on every path.
    public private(set) var modeFields: Set<String>?
    /// Shows the native sheet that confirms a mode which does not ask; Cancel answers false.
    public var requestModeConfirmation: (@MainActor (_ asked: AgentPaneModeConfirmation, _ answer: @escaping @MainActor (Bool) -> Void) -> Void)?
    /// `sessions.allowFullAccess`, read per frame: off, a switch into a full-access mode is refused.
    public var allowsFullAccess: @MainActor () -> Bool = { true }
    /// The app-wide gate: one mode confirmation open at a time, across all panes and windows.
    public var confirmationGate = AgentPaneConfirmationGate.shared
    /// acpmux's Enable harness prompt for `id` in `folder` (`_acpmux/harness_enable` without
    /// sha256, over the unix socket); throws when the daemon cannot give one (its refusal, as
    /// ``AcpmuxRPCError``, says why).
    public var harnessEnablePrompt: @MainActor (_ folder: String, _ id: String) async throws -> AgentPaneHarnessEnablePrompt = { _, _ in
        throw AcpmuxStatusClient.Failure.closed
    }
    /// Shows the native Enable harness sheet for `prompt`; Cancel answers false.
    public var requestHarnessEnable: (@MainActor (_ prompt: AgentPaneHarnessEnablePrompt, _ answer: @escaping @MainActor (Bool) -> Void) -> Void)?
    /// The current socket's request ids (relay-owned, mapped back on the reply).
    var requestIds: AcpmuxRequestIds?
    private(set) var socketPath: String?
    /// Told at each connect whether the pane runs on another cmux install's acpmux (its allows
    /// are refused here: the pane says so).
    public var onOtherInstall: (@MainActor (Bool) -> Void)?
    /// `_acpmux/markUnread` on the host's socket (Mark as Unread, cx-ncc.78). Replaced in tests.
    public var markUnread: @MainActor (_ sessionId: String) async throws -> Void = { _ in
        throw AcpmuxStatusClient.Failure.closed
    }

    /// Sends the pane's reply in place on as its chat's cmux agent message (``AgentPaneAgentReply``),
    /// for a chat on this Mac only; nil refuses every reply. The App wires it to this Mac's daemon.
    public var sendAgentReply: AgentPaneAgentReply.Send?
    /// What the socket calls: the ``sendAgentReply`` set now, not the one set when it opened. A
    /// prewarmed spare opens before its tab wires it, and a provisional tab's rekey rewires it.
    private var currentAgentReply: AgentPaneAgentReply.Send {
        { [weak self] reply in
            guard let send = self?.sendAgentReply else { throw AgentPaneAgentReply.Failure.unavailable }
            return try await send(reply)
        }
    }

    /// Keeps the prompts acpmux has not acknowledged across the app's end (``AgentPanePromptJournal``).
    public var promptJournal: AgentPanePromptJournal? = AgentPanePromptJournal.shared
    var promptRelay: AgentPanePromptRelay?

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
        markUnread = { [weak self] session in
            guard let path = self?.socketPath else { throw AcpmuxStatusClient.Failure.closed }
            try await AcpmuxStatusClient.markUnread(socketPath: path, sessionId: session)
        }
        harnessEnablePrompt = { [weak self] folder, id in
            guard let path = self?.socketPath else { throw AcpmuxStatusClient.Failure.closed }
            return try await AcpmuxStatusClient.harnessEnablePrompt(socketPath: path, folder: folder, id: id)
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
        questionKeyCredit = nil
        questionKeyTickets.removeAll()
        current += 1
        let id = current
        localAppToken = connection.localAppToken
        socketPath = connection.socketPath
        remoteApprovals = connection.remote?.approvals
        remoteHostID = connection.remote?.hostID
        remoteWire = connection.remote != nil
        trustDaemon = remoteWire ? nil : (connection.socketPath ?? connection.url.absoluteString)
        if let daemon = trustDaemon {
            bindPreOpenTrust(to: daemon)
            guard await restorePendingTrust(daemon: daemon, connection: id) else { throw .closed }
        }
        guard id == current else { throw .staleConnection }
        let wire = connection.remote?.makeWire()
        if let wire {
            remoteImageLoader = { path in try await wire.loadRemoteImage(path) }
            cloudRepository = { method, params, timeout in
                try await wire.cloudRepository(method: method, params: params, timeout: timeout)
            }
        } else {
            remoteImageLoader = nil
            cloudRepository = nil
        }
        if !remoteWire { remoteHomeChosen = [] }
        startCredit.clear()
        pickCredit.clear()
        decisions.reset()
        sentFirst = false
        promptRelay = AgentPanePromptRelay(connection, journal: promptJournal)
        let ids = AcpmuxRequestIds(promptAccepted: promptRelay?.forget)
        requestIds = ids
        let socket = AcpmuxPaneSocket(request: connection.request, wire: wire, limits: limits,
                                      options: permissionOptions, sessions: sessions, decisions: decisions,
                                      replacements: replacements, connection: id, ids: ids,
                                      agentReplies: connection.remote == nil ? currentAgentReply : nil,
                                      onQuestionStateChanged: onQuestionStateChanged) { [weak self] in
            // task-owner: one wake for the pacer; arrived(_:) ignores a stale connection
            Task { @MainActor [weak self] in self?.arrived(id) }
        }
        self.socket = socket
        onQuestionStateChanged?()
        // cx-fcaq: the local WebSocket goes only to a port the acpmux this app runs listens on.
        if connection.remote == nil, let executable = connection.executable, let port = connection.url.port,
           !(await AcpmuxServerPeer.verifyListener(port: port, executable: executable)) {
            if self.socket === socket { self.socket = nil; localAppToken = nil; trustDaemon = nil }
            throw .connectFailed
        }
        do {
            try await socket.start(timeout: limits.connectTimeout)
        } catch {
            if self.socket === socket { self.socket = nil; localAppToken = nil; trustDaemon = nil }
            Self.logger.error("agent pane transport connect failed connection=\(id, privacy: .public)")
            throw .connectFailed
        }
        guard self.socket === socket else { throw .staleConnection }
        // cx-fcaq: the accepted end of this connection is the acpmux this app runs too (or another
        // cmux install's, under AcpmuxServerPeer's rules; its allows stay with that app).
        if connection.remote == nil, let executable = connection.executable, let port = connection.url.port {
            guard let match = await AcpmuxServerPeer.verifyAccepted(port: port, executable: executable) else {
                close(connection: id)
                throw .connectFailed
            }
            onOtherInstall?(match == .foreign)
        } else {
            onOtherInstall?(false)
        }
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
        // A send ticket bound to a chat only for a chat of this pane.
        if let session = intent.sessionId, !sessions.contains(session) { return nil }
        // cx-0q7o: a permission answer's ticket only for a prompt of this pane's session that the
        // pane was shown, only for an option that prompt offers as an allow, and only right after
        // the person's own click (cx-ocdz: a posted click or a keystroke's gesture never answers).
        if intent.method == "_acpmux/permission_respond" {
            guard case .string(let session)? = intent.params["sessionId"], case .string(let permission)? = intent.params["permissionId"],
                  case .string(let option)? = intent.params["optionId"], sessions.contains(session),
                  permissionOptions.isKnownAllow(permissionId: permission, optionId: option) else { return nil }
            if let ticket = takeQuestionKeyTicket(intent) { return ticket }
            guard gestures.hasFreshAnswerGesture else { return nil }
        }
        // A prompt held for the folder trust answer right after a new chat's start: the start took
        // the send's gesture, and its credit becomes the prompt's ticket (the ticket outlives it).
        if intent.method == "session/prompt", !gestures.isAvailable,
           let fresh = startCredit.take(connection: current, now: gestures.uptime, lifetime: Self.startCreditLifetime) {
            return fresh ? gestures.reserve(connection: current, intent: intent, paid: true) : nil
        }
        return gestures.reserve(connection: current, intent: intent)
    }

    /// `uploads.begin {sessionId, promptId, ticket}`: the upload `upload` of the person's send holds
    /// its send ticket (``AgentPaneUserGestures/holdForUpload(_:upload:connection:sessionId:promptId:)``)
    /// on this connection, for a chat of this pane. False refuses the upload (`transport.gesture_required`).
    public func holdSendTicket(_ ticket: String, upload: String, sessionId: String, promptId: String) -> Bool {
        guard socket != nil, sessions.contains(sessionId) else { return false }
        return gestures.holdForUpload(ticket, upload: upload, connection: current, sessionId: sessionId, promptId: promptId)
    }

    /// Closes the connection if it is the current one.
    public func close(connection id: Int) {
        guard id == current else { return }
        failHostRequests(connection: id)
        failQuestionKeyReplies(connection: id, error: .closed)
        trustDaemon = nil // A new native pick after close belongs to the next local connection.
        guard let socket else { return }
        socket.close(code: 1000, reason: "", error: nil)
        gestures.recordQuestionReturn(false)
        gestures.clearTickets(connection: id)
        questionKeyCredit = nil
        questionKeyTickets = questionKeyTickets.filter { $0.value.connection != id }
        decisions.reset()
        onQuestionStateChanged?()
        localAppToken = nil
        promptRelay?.ended(byDaemon: false)
    }

    func offerQuestionKeyCredit(target: PageQuestionKeyTarget, intent: AgentPaneGestureIntent,
                                context: AcpmuxDecisionContexts.Context, connection: Int, witness: UUID,
                                redeem: @escaping @MainActor () async -> Bool) {
        guard connection == current, context.isQuestion else { return }
        questionKeyCredit = QuestionKeyCredit(target: target, intent: intent, context: context,
                                               connection: connection, witness: witness, redeem: redeem)
    }

    func takeQuestionKeyTicket(_ intent: AgentPaneGestureIntent) -> String? {
        guard let credit = questionKeyCredit, credit.connection == current,
              credit.intent == intent, gestures.questionReturnWitness == credit.witness else { return nil }
        questionKeyCredit = nil
        questionKeyTickets.removeAll()
        let ticket = UUID().uuidString
        questionKeyTickets[ticket] = credit
        return ticket
    }

    func takeQuestionKeyCredit(_ ticket: String, connection: Int) -> QuestionKeyCredit? {
        guard let credit = questionKeyTickets.removeValue(forKey: ticket), credit.connection == connection,
              gestures.questionReturnWitness == credit.witness else { return nil }
        return credit
    }

    private func arrived(_ id: Int) {
        guard id == current, let socket else { return }
        pacer.schedule(urgent: socket.pageWaits, answers: socket.answersWaiting) { [weak self] in self?.flush() ?? AgentPaneFlush(delivered: false, more: false) }
    }

    /// Delivers one batch, and says whether it made a call and whether more is waiting.
    @discardableResult
    func flush() -> AgentPaneFlush {
        guard let socket else { return AgentPaneFlush(delivered: false, more: false) }
        let batch = socket.take(maximumFrames: limits.maximumFramesPerFlush, maximumBytes: limits.maximumBytesPerFlush)
        // A peer of this Mac's daemon that has not enrolled this Mac refused its signed allow; an
        // answer that counted ends what the pane said.
        for answer in decisions.takeAnswers() where !remoteWire {
            switch answer {
            case .refused(let peer): onPeerApprovalsOff?(.notEnrolled(peer: peer))
            case .counted: onPeerApprovalsOff?(nil)
            }
        }
        guard !batch.frames.isEmpty || batch.closed != nil else { return AgentPaneFlush(delivered: false, more: batch.more) }
        flushes += 1
        finishQuestionKeyReplies(frames: batch.frames)
        var frames = batch.frames
        if let closed = batch.closed {
            frames += takeQuestionKeyRefusals(connection: current, error: closed.error ?? .closed)
        }
        let event = AgentPaneTransportEvent(connection: current, frames: frames, closed: batch.closed)
        if batch.closed != nil {
            failHostRequests(connection: current)
            self.socket = nil
            gestures.recordQuestionReturn(false)
            questionKeyCredit = nil
            questionKeyTickets.removeAll()
            onQuestionStateChanged?()
            trustDaemon = nil
            gestures.clearTickets(connection: current)
            localAppToken = nil
            // A connection the daemon closed: the page was told, so its prompts are the page's again
            // (Retry), unless Debug Settings agentPane.debug.lostPromptReplay sends them again.
            promptRelay?.ended(byDaemon: deliver != nil && !AgentPaneTunables.lostPromptReplay.value)
            // Kept in the log (notice, not info): the page's "connection interrupted" needs its reason.
            Self.logger.notice("agent pane transport closed connection=\(self.current, privacy: .public) code=\(batch.closed?.code ?? 0, privacy: .public) error=\(batch.closed?.error?.rawValue ?? "-", privacy: .public)")
        }
        let more = batch.more && self.socket != nil
        guard let deliver else { return AgentPaneFlush(delivered: false, more: more) }
        deliveries += 1
        let delivery = deliveries
        beforePageWork?()
        deliver(event) { [weak self] in
            guard let self, self.deliveries == delivery else { return }
            self.pacer.delivered()
        }
        if batch.closed != nil { pacer.reset() }
        return AgentPaneFlush(delivered: batch.closed == nil, more: more)
    }
}
