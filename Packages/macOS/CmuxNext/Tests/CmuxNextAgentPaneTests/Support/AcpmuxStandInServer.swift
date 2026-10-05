import Foundation
import Network
import Synchronization

/// A loopback WebSocket server that stands in for acpmux in the transport tests. Per connection it
/// records the upgrade's `Authorization` and `Origin` headers and every frame, answers every
/// request with an empty result (`initialize` with `origin: "local"`), and can push frames.
nonisolated final class AcpmuxStandInServer: Sendable {
    nonisolated struct Peer: Sendable {
        var authorization: String?
        var origin: String?
        var frames: [String] = []
        var closed = false
    }

    private struct State {
        var listener: NWListener?
        var connections: [NWConnection] = []
        var peers: [Peer] = []
        var lastHeaders: (String?, String?) = (nil, nil)
        var port: UInt16 = 0
        /// When false, requests get no reply (overflow tests push only).
        var answers = true
        /// The stream in flight (``stream(to:count:interval:)``).
        var stream: Stream?
        /// Methods whose replies wait for ``releaseHeld()``, and the replies waiting.
        var holding: Set<String> = []
        /// Results to answer instead of the default, by method (raw JSON).
        var results: [String: String] = [:]
        var held: [(String, Int)] = []
        var generation = 0
    }

    /// A timed stream: frame `i` is sent at `sent[i]` and acknowledged (`{"a":i}`) at `acked[i]`.
    struct Stream {
        var generation: Int
        var index: Int
        var sent: [UInt64]
        var acked: [UInt64]
        var remaining: Int
        var done: CheckedContinuation<Void, Never>?
    }

    private let queue = DispatchQueue(label: "acpmux.standin", qos: .userInitiated)
    private let state = Mutex(State())

    var port: UInt16 { state.withLock { $0.port } }
    var url: URL { URL(string: "ws://127.0.0.1:\(port)/")! }
    var peers: [Peer] { state.withLock { $0.peers } }
    func setAnswers(_ answers: Bool) { state.withLock { $0.answers = answers } }

    func start() async throws {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.setClientRequestHandler(queue) { [weak self] _, headers in
            let value = { (name: String) in headers.first { $0.name.lowercased() == name }?.value }
            self?.state.withLock { $0.lastHeaders = (value("authorization"), value("origin")) }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready = Mutex(false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { update in
                switch update {
                case .ready:
                    if ready.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume() }
                case .failed(let error):
                    if ready.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        state.withLock {
            $0.listener = listener
            $0.port = listener.port?.rawValue ?? 0
        }
    }

    func stop() {
        let (listener, connections) = state.withLock { ($0.listener, $0.connections) }
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let index = state.withLock { state -> Int in
            state.connections.append(connection)
            state.peers.append(Peer())
            return state.peers.count - 1
        }
        connection.stateUpdateHandler = { [weak self] update in
            if case .ready = update {
                self?.state.withLock { state in
                    state.peers[index].authorization = state.lastHeaders.0
                    state.peers[index].origin = state.lastHeaders.1
                }
            }
        }
        connection.start(queue: queue)
        receive(connection, index: index)
    }

    private func receive(_ connection: NWConnection, index: Int) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            guard error == nil, metadata?.opcode != .close else {
                self.state.withLock { $0.peers[index].closed = true }
                return
            }
            if let data, metadata?.opcode == .text { self.handle(String(decoding: data, as: UTF8.self), index: index) }
            self.receive(connection, index: index)
        }
    }

    private func handle(_ text: String, index: Int) {
        if text.hasPrefix(Self.ackPrefix) {
            let now = DispatchTime.now().uptimeNanoseconds
            let digits = text.dropFirst(Self.ackPrefix.count).prefix { $0.isNumber }
            let done = state.withLock { state -> CheckedContinuation<Void, Never>? in
                guard var stream = state.stream, stream.index == index,
                      let seq = Int(digits), stream.acked.indices.contains(seq), stream.acked[seq] == 0 else { return nil }
                stream.acked[seq] = now
                stream.remaining -= 1
                let done = stream.remaining == 0 ? stream.done : nil
                if done != nil { stream.done = nil }
                state.stream = stream
                return done
            }
            done?.resume()
            return
        }
        let answers = state.withLock { state -> Bool in
            state.peers[index].frames.append(text)
            return state.answers
        }
        guard answers, let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let id = object["id"], let method = object["method"] as? String,
              let idData = try? JSONSerialization.data(withJSONObject: [id]) else { return }
        let rawID = String(String(decoding: idData, as: UTF8.self).dropFirst().dropLast())
        let standard = switch method {
        case "initialize": #"{"protocolVersion":1,"_meta":{"acpmux":{"origin":"local","extensions":[]}}}"#
        case "session/new": #"{"sessionId":"s-new"}"#
        default: "{}"
        }
        let result = state.withLock { $0.results[method] } ?? standard
        let reply = #"{"jsonrpc":"2.0","id":"# + rawID + #","result":"# + result + "}"
        let hold = state.withLock { state -> Bool in
            guard state.holding.contains(method) else { return false }
            state.held.append((reply, index))
            return true
        }
        if !hold { push(reply, to: index) }
    }

    /// Answers every `method` request with `result` (raw JSON) from now on.
    func answer(_ method: String, with result: String) { state.withLock { $0.results[method] = result } }

    /// Holds the replies to `method` until ``releaseHeld()`` (a harness that takes its time).
    func hold(_ method: String) { state.withLock { _ = $0.holding.insert(method) } }

    func releaseHeld() {
        let held = state.withLock { state -> [(String, Int)] in
            state.holding.removeAll()
            defer { state.held.removeAll() }
            return state.held
        }
        for (reply, index) in held { push(reply, to: index) }
    }

    /// Sends `text` to connection `index`.
    func push(_ text: String, to index: Int) {
        guard let connection = state.withLock({ $0.connections.indices.contains(index) ? $0.connections[index] : nil }) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// A bench acknowledgement: an allowlisted notification, so it passes the relay as any page
    /// frame does: `{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"a<seq>"}}`.
    static let ackPrefix = #"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"a"#

    /// The bench's `session/update` frame (about 300 bytes) with sequence `seq`.
    static func benchFrame(_ seq: Int) -> String {
        #"{"jsonrpc":"2.0","method":"session/update","params":{"s":"# + String(seq)
            + #","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":""#
            + String(repeating: "x", count: 200) + #""}}}}"#
    }

    /// Sends `count` bench frames to connection `index`, back to back (`interval` 0) or one every
    /// `interval` nanoseconds, and returns each frame's send-to-acknowledgement time (ns) and the
    /// time from the first send to the last acknowledgement.
    func stream(to index: Int, count: Int, interval: UInt64 = 0) async -> (latencies: [UInt64], total: UInt64) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let generation = state.withLock { state -> Int in
                state.generation += 1
                state.stream = Stream(generation: state.generation, index: index, sent: Array(repeating: 0, count: count),
                                      acked: Array(repeating: 0, count: count), remaining: count, done: continuation)
                return state.generation
            }
            // A lost acknowledgement ends the stream after a minute instead of hanging the bench.
            queue.asyncAfter(deadline: .now() + 60) { [weak self] in
                let late = self?.state.withLock { state -> CheckedContinuation<Void, Never>? in
                    guard let stream = state.stream, stream.generation == generation, stream.remaining > 0 else { return nil }
                    print("STANDIN-STREAM timed out: \(stream.remaining) of \(stream.sent.count) frames unacknowledged")
                    let done = stream.done
                    state.stream?.done = nil
                    return done
                }
                late?.resume()
            }
            queue.async {
                let start = DispatchTime.now().uptimeNanoseconds
                for seq in 0..<count {
                    let send = { [weak self] in
                        guard let self else { return }
                        self.state.withLock { $0.stream?.sent[seq] = DispatchTime.now().uptimeNanoseconds }
                        self.push(Self.benchFrame(seq), to: index)
                    }
                    if interval == 0 { send() } else {
                        self.queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: start + UInt64(seq) * interval), execute: send)
                    }
                }
            }
        }
        return state.withLock { state in
            guard let stream = state.stream else { return ([], 0) }
            state.stream = nil
            return (zip(stream.sent, stream.acked).map { $1 &- $0 }, (stream.acked.max() ?? 0) &- (stream.sent.min() ?? 0))
        }
    }

    /// Waits (polling the recorded state; test helper) until `condition` holds or `seconds` pass.
    func wait(seconds: Double = 10, until condition: @Sendable ([Peer]) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition(peers) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition(peers)
    }
}
