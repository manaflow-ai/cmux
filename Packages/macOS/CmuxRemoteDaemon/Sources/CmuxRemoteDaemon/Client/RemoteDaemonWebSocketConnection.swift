internal import Foundation
import Network

private final class RemoteDaemonWebSocketCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let completion: @Sendable ((any Error)?) -> Void

    init(completion: @escaping @Sendable ((any Error)?) -> Void) {
        self.completion = completion
    }

    func finish(_ error: (any Error)?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        completion(error)
    }
}

/// Owns one Network.framework WebSocket with explicit cancellation semantics.
/// The synchronous open wait is retained because the RPC client start contract
/// is synchronous; the short lock only protects that low-level callback bridge.
final class RemoteDaemonWebSocketConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let callbackQueue: DispatchQueue
    private let openSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false
    private var closed = false

    init(request: URLRequest, callbackQueue: DispatchQueue) throws {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            throw URLError(.badURL)
        }

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        // A 4 MiB daemon request expands when base64-encoded in a cli.request event.
        webSocketOptions.maximumMessageSize = 8 * 1024 * 1024
        if let headers = request.allHTTPHeaderFields {
            webSocketOptions.setAdditionalHeaders(headers.map { (name: $0.key, value: $0.value) })
        }

        let parameters: NWParameters = scheme == "wss" ? .tls : .tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        self.connection = connection
        self.callbackQueue = callbackQueue
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state)
        }
        connection.start(queue: callbackQueue)
    }

    deinit { connection.cancel() }

    func waitForOpen(timeout: TimeInterval) -> Bool {
        if openSemaphore.wait(timeout: .now() + timeout) != .success {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        return opened && !closed
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func receiveMessage(
        _ completion: @escaping @Sendable (Data?, NWProtocolWebSocket.Opcode?, Bool, NWError?) -> Void
    ) {
        connection.receiveMessage { data, context, isComplete, error in
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
            completion(data, opcode, isComplete, error)
        }
    }

    func sendText(_ text: String, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "remote-daemon.send", metadata: [metadata])
        connection.send(
            content: Data(text.utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in completion(error) }
        )
    }

    func sendPing(completion: @escaping @Sendable ((any Error)?) -> Void) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        let gate = RemoteDaemonWebSocketCompletionGate(completion: completion)
        metadata.setPongHandler(callbackQueue) { error in
            gate.finish(error)
        }
        let context = NWConnection.ContentContext(identifier: "remote-daemon.ping", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            if let error {
                gate.finish(error)
            }
        })
    }

    func cancel() {
        lock.lock()
        closed = true
        lock.unlock()
        openSemaphore.signal()
        connection.cancel()
    }

    private func handle(state: NWConnection.State) {
        lock.lock()
        switch state {
        case .ready:
            opened = true
        case .failed:
            closed = true
            lock.unlock()
            openSemaphore.signal()
            connection.cancel()
            return
        case .cancelled:
            closed = true
        default:
            lock.unlock()
            return
        }
        lock.unlock()
        openSemaphore.signal()
    }
}
