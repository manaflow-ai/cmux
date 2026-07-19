import Foundation

/// WebSocket transport for the host's share-session connection.
///
/// One `URLSessionWebSocketTask` at a time; JSON text frames plus binary grid
/// frames out, JSON text frames in. Reconnects with exponential backoff,
/// minting a fresh host token via `ShareSessionAPI` before every reconnect
/// attempt (the create-time token is short-TTL). All callbacks fire on the
/// main actor.
@MainActor
final class ShareSocket {
    struct Endpoint: Sendable {
        var wsUrl: String
        var token: String
    }

    /// Fired after the socket (re)opens; the controller re-sends `hello`.
    var onOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    var onConnectionStateChange: ((Bool) -> Void)?

    private let initialEndpoint: Endpoint
    private let refreshEndpoint: @Sendable () async throws -> Endpoint
    private var runTask: Task<Void, Never>?
    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isStopped = false

    init(endpoint: Endpoint, refresh: @escaping @Sendable () async throws -> Endpoint) {
        self.initialEndpoint = endpoint
        self.refreshEndpoint = refresh
    }

    func start() {
        guard runTask == nil, !isStopped else { return }
        runTask = Task { @MainActor [weak self] in
            await self?.runLoop()
        }
    }

    /// Cleanly closes the connection and stops reconnecting.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        runTask?.cancel()
        runTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        onConnectionStateChange?(false)
    }

    func send(_ message: ShareHostMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        send(text: text)
    }

    func send(text: String) {
        task?.send(.string(text)) { error in
            #if DEBUG
            if let error {
                cmuxDebugLog("share.socket send text failed: \(error.localizedDescription)")
            }
            #endif
        }
    }

    func send(data: Data) {
        task?.send(.data(data)) { error in
            #if DEBUG
            if let error {
                cmuxDebugLog("share.socket send data failed: \(error.localizedDescription)")
            }
            #endif
        }
    }

    // MARK: - Connection loop

    private func runLoop() async {
        var endpoint = initialEndpoint
        var attempt = 0
        var isFirstAttempt = true
        while !Task.isCancelled, !isStopped {
            if !isFirstAttempt {
                // Backoff, then refresh the short-TTL host token before dialing.
                let delay = Self.backoffSeconds(attempt: attempt)
                attempt += 1
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch { return }
                guard !isStopped else { return }
                do {
                    endpoint = try await refreshEndpoint()
                } catch {
                    #if DEBUG
                    cmuxDebugLog("share.socket token refresh failed: \(error)")
                    #endif
                    continue
                }
                guard !isStopped else { return }
            }
            isFirstAttempt = false

            guard let url = Self.connectionURL(endpoint: endpoint) else {
                #if DEBUG
                cmuxDebugLog("share.socket invalid wsUrl: \(endpoint.wsUrl)")
                #endif
                return
            }

            let delegate = ShareSocketOpenDelegate()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let socketTask = session.webSocketTask(with: url)
            urlSession = session
            task = socketTask
            socketTask.resume()

            let opened = await delegate.waitForOpen()
            guard !isStopped else {
                session.invalidateAndCancel()
                return
            }
            guard opened else {
                session.invalidateAndCancel()
                if task === socketTask { task = nil; urlSession = nil }
                continue
            }

            attempt = 0
            onConnectionStateChange?(true)
            onOpen?()
            await receiveLoop(socketTask)
            onConnectionStateChange?(false)
            session.invalidateAndCancel()
            if task === socketTask {
                task = nil
                urlSession = nil
            }
        }
    }

    private func receiveLoop(_ socketTask: URLSessionWebSocketTask) async {
        while !Task.isCancelled, !isStopped {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socketTask.receive()
            } catch {
                #if DEBUG
                cmuxDebugLog("share.socket receive ended: \(error.localizedDescription)")
                #endif
                return
            }
            switch message {
            case .string(let text):
                onText?(text)
            case .data:
                // The DO never sends binary frames to the host.
                break
            @unknown default:
                break
            }
        }
    }

    private static func connectionURL(endpoint: Endpoint) -> URL? {
        guard var components = URLComponents(string: endpoint.wsUrl) else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "token" }
        items.append(URLQueryItem(name: "token", value: endpoint.token))
        components.queryItems = items
        return components.url
    }

    static func backoffSeconds(attempt: Int) -> Double {
        let base = min(30.0, 0.5 * pow(2.0, Double(min(attempt, 8))))
        return base + Double.random(in: 0...(base * 0.25))
    }
}

/// Bridges `URLSessionWebSocketDelegate` open/close callbacks into one
/// awaitable open result per connection attempt. Handshake failures surface
/// through `didCompleteWithError` (bounded by the session's request timeout).
private final class ShareSocketOpenDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func waitForOpen() async -> Bool {
        await withCheckedContinuation { cont in
            lock.lock()
            if let result {
                lock.unlock()
                cont.resume(returning: result)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    private func finish(_ opened: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = opened
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: opened)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        finish(true)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(false)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(false)
    }
}
