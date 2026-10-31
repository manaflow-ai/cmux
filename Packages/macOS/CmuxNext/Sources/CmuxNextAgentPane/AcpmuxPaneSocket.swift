import Foundation
import CmuxNextCompat

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
        /// The inbox's first frames up to the last one the page waits on (``pageWaits``); 0 for none.
        var awaitedThrough = 0
        /// The inbox's first frames up to the last reply to the page's own request (``answersPage``); 0 for none.
        var answeredThrough = 0
        /// Daemon frames received and not checked yet, and whether a pass over them is running.
        var raw: [String] = []
        var rawBytes = 0
        var processing = false
        var questionNotificationQueued = false
        var signaled = false
        var outstanding = 0
        var outstandingBytes = 0
        var closed: AgentPaneTransportClose?
        var closeDelivered = false
        /// Told the queue's length after each enqueue (tests wait on it instead of a clock).
        var onQueued: (@Sendable (Int) -> Void)?
        /// The daemon's person challenge from the `initialize` reply (cx-fcaq): unread, read
        /// (nil when the reply had none), and who waits for it.
        var challengeRead = false
        var challenge: AcpmuxPersonChallenge?
        var challengeWaiters: [CheckedContinuation<AcpmuxPersonChallenge?, Never>] = []

        /// A full flush waits: it goes even to a pane nobody can see (``pageWaits``).
        func backlogged(_ limits: AgentPaneTransport.Limits) -> Bool {
            inbox.count >= limits.maximumFramesPerFlush || inboxBytes >= limits.maximumBytesPerFlush
        }
    }

    private let request: URLRequest
    /// The path for a chat on another machine (``AcpmuxPaneWire``); nil for the local WebSocket.
    private let wire: (any AcpmuxPaneWire)?
    private let limits: AgentPaneTransport.Limits
    private let options: AcpmuxPermissionOptions
    private let sessions: AcpmuxPaneSessions
    private let decisions: AcpmuxDecisionContexts
    private let replacements: AcpmuxPaneReplacements
    /// The transport's id for this socket's connection (``AcpmuxPaneReplacements``).
    private let connection: Int

    /// A page frame with this decoded `method` is about to go out on this socket: false refuses it
    /// (a start or open while a Sandboxed send runs, ``AcpmuxPaneReplacements``).
    func sendingPageFrame(method: String?) -> Bool {
        replacements.sending(method: method, connection: connection)
    }

    /// A start or open refused now while a Sandboxed send runs (``AcpmuxPaneReplacements/refuses(method:)``).
    func refusesPageFrame(method: String?) -> Bool {
        replacements.refuses(method: method)
    }

    /// A page frame ``sendingPageFrame(method:)`` let through did not go out.
    func pageFrameNotSent(method: String?) {
        replacements.notSent(method: method, connection: connection)
    }
    private let ids: AcpmuxRequestIds
    /// Sends a reply in place on (``AgentPaneAgentReply``); nil refuses every one.
    private let agentReplies: AgentPaneAgentReply.Send?
    private let onQuestionStateChanged: (@MainActor () -> Void)?
    private let signal: @Sendable () -> Void
    private let state = Mutex(State())
    let statusRead = AcpmuxStatusReadSlot()
    /// Checks the daemon's frames in passes, in order, while the receive loop goes on.
    private let inbound = DispatchQueue(label: "com.cmuxterm.app.next.agent-pane.inbound", qos: .userInitiated)

    init(request: URLRequest, wire: (any AcpmuxPaneWire)? = nil, limits: AgentPaneTransport.Limits,
         options: AcpmuxPermissionOptions, sessions: AcpmuxPaneSessions, decisions: AcpmuxDecisionContexts = AcpmuxDecisionContexts(),
         replacements: AcpmuxPaneReplacements = AcpmuxPaneReplacements(), connection: Int = 0, ids: AcpmuxRequestIds, agentReplies: AgentPaneAgentReply.Send? = nil, onQuestionStateChanged: (@MainActor () -> Void)? = nil, signal: @escaping @Sendable () -> Void) {
        self.request = request
        self.wire = wire
        self.limits = limits
        self.options = options
        self.sessions = sessions
        self.decisions = decisions
        self.replacements = replacements
        self.connection = connection
        self.ids = ids
        self.agentReplies = agentReplies
        self.onQuestionStateChanged = onQuestionStateChanged
        self.signal = signal
    }

    func start(timeout: TimeInterval) async throws {
        if let wire { return try await start(wire) }
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

    /// Opens the wire; its frames take the same inbound path as the WebSocket's.
    private func start(_ wire: any AcpmuxPaneWire) async throws {
        guard state.withLock({ $0.closed == nil }) else { throw AgentPaneTransportError.closed }
        try await wire.open(onFrame: { [weak self] text in self?.arrived(text) },
                            onClose: { [weak self] code, reason in self?.daemonClosed(code: code, reason: reason) })
        let closed = state.withLock { state -> Bool in
            guard state.closed == nil else { return true }
            state.opened = true
            return false
        }
        if closed {
            wire.cancel(code: 1000, reason: "")
            throw AgentPaneTransportError.closed
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
            case .failure: return self.daemonClosed(code: 1006, reason: "")
            }
            self.receive(task)
        }
    }

    /// A daemon frame: it waits for the next pass (``process()``), which checks every waiting
    /// frame in one hop. The bound covers the frames waiting and the frames queued for the page.
    /// A host read uses the daemon reply path, including its bounds, ids and reply filtering.
    func receiveLocalReply(_ text: String) { arrived(text) }

    private func arrived(_ received: String) {
        let bytes = received.utf8.count
        let (start, overflow) = state.withLock { state -> (Bool, Bool) in
            guard state.closed == nil else { return (false, false) }
            if state.raw.count + state.inbox.count >= limits.maximumQueuedFrames
                || state.rawBytes + state.inboxBytes + bytes > limits.maximumQueuedBytes {
                return (false, true)
            }
            state.raw.append(received)
            state.rawBytes += bytes
            guard !state.processing else { return (false, false) }
            state.processing = true
            return (true, false)
        }
        if overflow { close(code: 1008, reason: "inbound overflow", error: .inboundOverflow) }
        if start { inbound.async { [self] in process() } }
    }

    /// One pass after another over the waiting daemon frames, in order: the duplicate check, one
    /// parse, the observers (from that parse), the fresh serialization; then one wake for the page.
    private func process() {
        var batch = takeRaw()
        while !batch.isEmpty {
            var page: [String] = []
            var awaited = 0
            var answers = 0
            var questionsChanged = false
            for text in batch {
                switch ids.toPage(text) {
                case .drop:
                    continue
                case .close:
                    enqueue(page, awaited: awaited, answers: answers)
                    state.withLock { $0.processing = false }
                    return close(code: 1008, reason: "duplicate key", error: .duplicateKey)
                case .page(let fresh, let object, let method):
                    if method == AcpmuxPaneMethods.initialize { readChallenge(object) }
                    // The observers read the same parse the page gets.
                    options.observe(object, replyTo: method)
                    sessions.observe(object)
                    sessions.observeFolder(object, replyTo: method)
                    if wire != nil { sessions.observeTabSession(object, replyTo: method) }
                    let questionVersion = decisions.pendingQuestionVersion()
                    decisions.observe(object, replyTo: method)
                    questionsChanged = questionsChanged || decisions.pendingQuestionVersion() != questionVersion
                    replacements.observe(object, replyTo: method, connection: connection)
                    if Self.pageWaits(on: object) { awaited += 1 }
                    if Self.answersPage(object) { answers += 1 }
                    page.append(fresh)
                case .complete(let object, let pageID, let subject):
                    switch AgentPaneAgentReply.step(object, pageID: pageID, subject: subject, sessions: sessions,
                                                    canSend: agentReplies != nil) {
                    case .answer(let frame): if let frame { page.append(frame) }
                    case .send(let reply): sendReply(reply, pageID: pageID)
                    }
                }
            }
            enqueue(page, awaited: awaited, answers: answers)
            if questionsChanged { notifyQuestionsChanged() }
            batch = takeRaw()
        }
    }

    private func notifyQuestionsChanged() {
        let queue = state.withLock { state in
            guard !state.questionNotificationQueued else { return false }
            state.questionNotificationQueued = true
            return true
        }
        guard queue else { return }
        // task-owner: one coalesced native projection update, only after question state changes.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state.withLock { $0.questionNotificationQueued = false }
            self.onQuestionStateChanged?()
        }
    }

    /// Sends a reply in place on as its chat; the page gets the answer once the daemon took it or
    /// refused it, after the frames already queued.
    private func sendReply(_ reply: AgentPaneAgentReply, pageID: String) {
        guard let agentReplies else { return }
        // task-owner: one reply's send; its answer joins the page queue, which a closed socket drops
        Task { [weak self] in
            let answer = await AgentPaneAgentReply.sent(reply, pageID: pageID, send: agentReplies)
            if let answer { self?.inject(answer) }
        }
    }

    /// The `initialize` reply's `_meta.acpmux.personChallenge`, for the host's proof.
    private func readChallenge(_ object: [String: Any]) {
        let challenge = (((object["result"] as? [String: Any])?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])?["personChallenge"]
            .flatMap { $0 as? [String: Any] }
            .flatMap { c -> AcpmuxPersonChallenge? in
                guard let nonce = c["nonce"] as? String, let connection = c["connection"] as? String else { return nil }
                return AcpmuxPersonChallenge(nonce: nonce, connection: connection)
            }
        resolveChallenge(challenge)
    }

    private func resolveChallenge(_ challenge: AcpmuxPersonChallenge?) {
        let waiters = state.withLock { state -> [CheckedContinuation<AcpmuxPersonChallenge?, Never>] in
            guard !state.challengeRead else { return [] }
            state.challengeRead = true
            state.challenge = challenge
            defer { state.challengeWaiters = [] }
            return state.challengeWaiters
        }
        for waiter in waiters { waiter.resume(returning: challenge) }
    }

    /// The person challenge of this connection, once the `initialize` reply arrived; nil when it
    /// had none or the socket closed first. Only the local WebSocket has one (not a remote wire).
    func personChallenge() async -> AcpmuxPersonChallenge? {
        guard wire == nil else { return nil }
        return await withCheckedContinuation { waiter in
            let now = state.withLock { state -> (Bool, AcpmuxPersonChallenge?) in
                if state.challengeRead || state.closed != nil { return (true, state.challenge) }
                state.challengeWaiters.append(waiter)
                return (false, nil)
            }
            if now.0 { waiter.resume(returning: now.1) }
        }
    }

    /// The waiting daemon frames; an empty take ends the pass (under the same lock as `arrived`).
    private func takeRaw() -> [String] {
        state.withLock { state in
            let batch = state.raw
            state.raw = []
            state.rawBytes = 0
            if batch.isEmpty { state.processing = false }
            return batch
        }
    }

    /// Whether a pane nobody can see gets the waiting frames now (``pageWaits(on:)``).
    var pageWaits: Bool { state.withLock { $0.awaitedThrough > 0 || $0.closed != nil || $0.backlogged(limits) } }

    /// Whether the waiting frames answer a request the page sent (``answersPage(_:)``): a pane nobody
    /// can see gets them without its hidden interval (``AgentPaneFramePacer``).
    var answersWaiting: Bool { state.withLock { $0.answeredThrough > 0 } }

    /// Frames for the page, in order, with one wake for the pacer; `awaited` of them the page waits
    /// on, `answers` of those replies to its own requests.
    private func enqueue(_ frames: [String], awaited: Int = 0, answers: Int = 0) {
        guard !frames.isEmpty else { return }
        let bytes = frames.reduce(0) { $0 + $1.utf8.count }
        let (wake, queued, onQueued) = state.withLock { state -> (Bool, Int, (@Sendable (Int) -> Void)?) in
            guard state.closed == nil else { return (false, 0, nil) }
            state.inbox.append(contentsOf: frames)
            state.inboxBytes += bytes
            if awaited > 0 { state.awaitedThrough = state.inbox.count }
            if answers > 0 { state.answeredThrough = state.inbox.count }
            // A pacer holding a hidden pane's frames is woken again for frames its page waits on.
            let wake = !state.signaled || awaited > 0 || state.backlogged(limits)
            state.signaled = true
            return (wake, state.inbox.count, state.onQueued)
        }
        if wake { signal() }
        onQueued?(queued)
    }

    var isClosed: Bool { state.withLock { $0.closed != nil } }

    var queuedFrames: Int { state.withLock { $0.inbox.count } }

    /// Queues a frame the host made (a refusal) as if the daemon had sent it.
    /// The relay's own answer to a refused request, straight to the page queue. It can reach the page
    /// before earlier daemon frames that still wait in `raw` for the inbound pass.
    func inject(_ text: String) { enqueue([text], awaited: 1, answers: 1) }

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
            state.awaitedThrough = max(0, state.awaitedThrough - count)
            state.answeredThrough = max(0, state.answeredThrough - count)
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
        if let wire { return send(text, on: wire) }
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
                if error != nil { self.daemonClosed(code: 1006, reason: "") }
            }
            return nil
        }
    }

    /// The wire's send, under the same outstanding bounds as the WebSocket's.
    private func send(_ text: String, on wire: any AcpmuxPaneWire) -> AgentPaneTransportError? {
        let bytes = text.utf8.count
        let refusal = state.withLock { state -> AgentPaneTransportError? in
            guard state.closed == nil, state.opened else { return .closed }
            guard state.outstanding < limits.maximumOutstandingSends,
                  state.outstandingBytes + bytes <= limits.maximumOutstandingBytes else { return .outboundOverflow }
            state.outstanding += 1
            state.outstandingBytes += bytes
            return nil
        }
        if let refusal { return refusal }
        wire.send(text) { [weak self] sent in
            guard let self else { return }
            self.state.withLock { state in
                state.outstanding -= 1
                state.outstandingBytes -= bytes
            }
            if !sent { self.daemonClosed(code: 1006, reason: "") }
        }
        return nil
    }

    // MARK: Close

    /// Closes the socket (the host's decision): queued inbound frames are dropped on an error.
    func close(code: Int, reason: String, error: AgentPaneTransportError?) {
        let (task, session, wake, first) = state.withLock { state -> (URLSessionWebSocketTask?, URLSession?, Bool, Bool) in
            guard state.closed == nil else { return (nil, nil, false, false) }
            state.closed = AgentPaneTransportClose(code: code, reason: reason, error: error)
            if error != nil {
                state.inbox.removeAll()
                state.awaitedThrough = 0
                state.answeredThrough = 0
                state.inboxBytes = 0
            }
            // Always woken: the close goes even to a hidden pane (``pageWaits``).
            state.signaled = true
            return (state.task, state.session, true, true)
        }
        task?.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: Data(reason.utf8))
        session?.finishTasksAndInvalidate()
        if first, let wire { wire.cancel(code: code, reason: reason) }
        resolveChallenge(nil)
        if wake { signal() }
    }

    /// The socket ended on its own (the daemon closed it, or IO failed). The close goes through the
    /// inbound queue, after every frame that arrived before it, so the page gets the daemon's last
    /// frames first. (A host close with an error, ``close(code:reason:error:)``, still drops them.)
    private func daemonClosed(code: Int, reason: String) {
        inbound.async { [self] in finish(code: code, reason: reason, error: nil) }
    }

    private func finish(code: Int, reason: String, error: AgentPaneTransportError?) {
        let (opening, session, wake) = state.withLock { state -> (CheckedContinuation<Void, any Error>?, URLSession?, Bool) in
            let opening = state.opening
            state.opening = nil
            guard state.closed == nil else { return (opening, nil, false) }
            state.closed = AgentPaneTransportClose(code: code, reason: reason, error: error)
            state.signaled = true
            return (opening, state.session, true)
        }
        opening?.resume(throwing: AgentPaneTransportError.connectFailed)
        session?.finishTasksAndInvalidate()
        resolveChallenge(nil)
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
        daemonClosed(code: closeCode.rawValue, reason: reason.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        daemonClosed(code: 1006, reason: "")
    }
}
