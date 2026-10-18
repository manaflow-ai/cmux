internal import Foundation

/// URLSession delegate that converts WebSocket open/close callbacks into a
/// blocking "did the socket open" handshake for
/// ``RemoteDaemonRPCClient``'s synchronous start path (faithful lift of the
/// client's nested `WebSocketDelegate`).
///
/// Isolation design (lock + semaphore, deliberately not an actor):
/// - **Who mutates:** URLSession's delegate queue sets `opened`/`closed`
///   under `lock` and signals `openSemaphore`.
/// - **Who reads:** the thread blocked in ``waitForOpen(timeout:)`` (it
///   cannot await; `start()` is synchronous by contract) and the client's
///   state queue via ``isClosed``, both under `lock`.
/// - **Why this primitive:** two Bool flags read by synchronous code is
///   exactly the sanctioned tiny-lock shape; the blocking handshake is
///   load-bearing for the legacy start ordering. Async migration is a
///   deliberate later-phase item (plan: "Modernization hot-spots (migrate in
///   a later phase)").
final class RemoteDaemonWebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    // @unchecked Sendable: both flags are guarded by `lock`; the semaphore
    // carries the open/close edge to the blocked waiter.
    private let openSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false
    private var closed = false

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        opened = true
        lock.unlock()
        openSemaphore.signal()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        lock.lock()
        closed = true
        lock.unlock()
        openSemaphore.signal()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard error != nil else { return }
        lock.lock()
        closed = true
        lock.unlock()
        openSemaphore.signal()
    }

    /// Blocks until the socket reports open or closed (or `timeout` elapses);
    /// `true` only when it opened and has not closed.
    func waitForOpen(timeout: TimeInterval) -> Bool {
        if openSemaphore.wait(timeout: .now() + timeout) != .success {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        return opened && !closed
    }

    /// Whether the socket has reported close.
    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}

/// Multiplexes delegate callbacks from a shared URLSession across concurrently
/// active or sequential WebSocket tasks.
final class RemoteDaemonWebSocketMultiplexer: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var delegates: [Int: RemoteDaemonWebSocketDelegate] = [:]

    func register(delegate: RemoteDaemonWebSocketDelegate, for task: URLSessionWebSocketTask) {
        lock.lock()
        delegates[task.taskIdentifier] = delegate
        lock.unlock()
    }

    @discardableResult
    func unregister(task: URLSessionWebSocketTask) -> RemoteDaemonWebSocketDelegate? {
        lock.lock()
        defer { lock.unlock() }
        return delegates.removeValue(forKey: task.taskIdentifier)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        let delegate: RemoteDaemonWebSocketDelegate? = {
            lock.lock()
            defer { lock.unlock() }
            return delegates[webSocketTask.taskIdentifier]
        }()
        delegate?.urlSession(session, webSocketTask: webSocketTask, didOpenWithProtocol: `protocol`)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let delegate = unregister(task: webSocketTask)
        delegate?.urlSession(session, webSocketTask: webSocketTask, didCloseWith: closeCode, reason: reason)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let wsTask = task as? URLSessionWebSocketTask else { return }
        let delegate: RemoteDaemonWebSocketDelegate? = error != nil ? unregister(task: wsTask) : {
            lock.lock()
            defer { lock.unlock() }
            return delegates[wsTask.taskIdentifier]
        }()
        delegate?.urlSession(session, task: task, didCompleteWithError: error)
    }
}
