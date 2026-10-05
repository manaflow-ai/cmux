import Foundation
import Synchronization

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
        /// Daemon frames received and not checked yet, and whether a pass over them is running.
        var raw: [String] = []
        var rawBytes = 0
        var processing = false
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
    /// Checks the daemon's frames in passes, in order, while the receive loop goes on.
    private let inbound = DispatchQueue(label: "com.cmuxterm.app.next.agent-pane.inbound", qos: .userInitiated)

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
            case .failure: return self.daemonClosed(code: 1006, reason: "")
            }
            self.receive(task)
        }
    }

    /// A daemon frame: it waits for the next pass (``process()``), which checks every waiting
    /// frame in one hop. The bound covers the frames waiting and the frames queued for the page.
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
            for text in batch {
                switch ids.toPage(text) {
                case .drop:
                    continue
                case .close:
                    enqueue(page)
                    state.withLock { $0.processing = false }
                    return close(code: 1008, reason: "duplicate key", error: .duplicateKey)
                case .page(let fresh, let object, let method):
                    // The observers read the same parse the page gets.
                    options.observe(object, replyTo: method)
                    sessions.observe(object)
                    page.append(fresh)
                }
            }
            enqueue(page)
            batch = takeRaw()
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

    /// Frames for the page, in order, with one wake for the pacer.
    private func enqueue(_ frames: [String]) {
        guard !frames.isEmpty else { return }
        let bytes = frames.reduce(0) { $0 + $1.utf8.count }
        let wake = state.withLock { state -> Bool in
            guard state.closed == nil else { return false }
            state.inbox.append(contentsOf: frames)
            state.inboxBytes += bytes
            guard !state.signaled else { return false }
            state.signaled = true
            return true
        }
        if wake { signal() }
    }

    var queuedFrames: Int { state.withLock { $0.inbox.count } }

    /// Queues a frame the host made (a refusal) as if the daemon had sent it.
    /// The relay's own answer to a refused request, straight to the page queue. It can reach the page
    /// before earlier daemon frames that still wait in `raw` for the inbound pass.
    func inject(_ text: String) { enqueue([text]) }

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
                if error != nil { self.daemonClosed(code: 1006, reason: "") }
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
        daemonClosed(code: closeCode.rawValue, reason: reason.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        daemonClosed(code: 1006, reason: "")
    }
}
