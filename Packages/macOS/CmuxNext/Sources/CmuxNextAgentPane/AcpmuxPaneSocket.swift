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
        let text: String
        if fromDaemon {
            switch ids.toPage(received) {
            case .drop: return
            case .close: return close(code: 1008, reason: "duplicate key", error: .duplicateKey)
            case .page(let fresh, let object, let method):
                // The observers read the same parse the page gets.
                options.observe(object, replyTo: method)
                sessions.observe(object)
                text = fresh
            }
        } else {
            text = received
        }
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
