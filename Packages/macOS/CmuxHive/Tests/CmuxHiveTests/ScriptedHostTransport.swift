import CMUXMobileCore
import Foundation

/// A scripted fake of the Mac host's RPC endpoint at the byte-transport seam:
/// decodes request frames, answers by method from a handler table, and lets
/// tests push server events / kill the connection to exercise recovery.
actor ScriptedHostTransport: CmxByteTransport {
    typealias Handler = @Sendable (_ method: String, _ params: [String: Any]) -> [String: Any]

    private let handler: Handler
    private var inbound = Data()
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var pendingResponses: [Data] = []
    private var isClosed = false
    private(set) var connectCount = 0
    private(set) var sentMethods: [String] = []
    private(set) var sentInputTexts: [String] = []
    private struct MethodWaiter {
        let method: String
        let count: Int
        let continuation: AsyncStream<Void>.Continuation
    }
    private struct ResponseEvent {
        let method: String
        let occurrence: Int
        let frame: Data
    }
    enum WaitError: Error { case methodNotReceived(String) }
    private var methodWaiters: [UUID: MethodWaiter] = [:]
    private var responseEvents: [ResponseEvent] = []
    private var failingResponseOccurrences: [String: Set<Int>] = [:]
    private var droppedResponseOccurrences: [String: Set<Int>] = [:]
    private var heldResponseOccurrences: [String: Set<Int>] = [:]
    private var heldResponses: [String: [Int: Data]] = [:]

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func connect() async throws {
        connectCount += 1
        isClosed = false
    }

    func receive() async throws -> Data? {
        if isClosed { return nil }
        if !pendingResponses.isEmpty {
            return pendingResponses.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        if isClosed { throw CancellationError() }
        inbound.append(data)
        let frames = (try? MobileSyncFrameCodec.decodeFrames(from: &inbound)) ?? []
        for frame in frames {
            guard let request = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  let id = request["id"] as? String,
                  let method = request["method"] as? String else { continue }
            let params = request["params"] as? [String: Any] ?? [:]
            sentMethods.append(method)
            if method == "mobile.terminal.input", let text = params["text"] as? String {
                sentInputTexts.append(text)
            }
            resolveMethodWaiters(method: method)
            let occurrence = sentMethods.filter { $0 == method }.count
            let result = handler(method, params)
            let envelope: [String: Any]
            if failingResponseOccurrences[method]?.contains(occurrence) == true {
                envelope = [
                    "id": id, "ok": false,
                    "error": ["code": "scripted_failure", "message": "Scripted RPC failure"],
                ]
            } else {
                envelope = ["id": id, "ok": true, "result": result]
            }
            if droppedResponseOccurrences[method]?.contains(occurrence) != true,
               let payload = try? JSONSerialization.data(withJSONObject: envelope),
               let framed = try? MobileSyncFrameCodec.encodeFrame(payload) {
                if heldResponseOccurrences[method]?.contains(occurrence) == true {
                    heldResponses[method, default: [:]][occurrence] = framed
                } else {
                    deliver(framed)
                }
            }
            for event in responseEvents where event.method == method && event.occurrence == occurrence {
                deliver(event.frame)
            }
        }
    }

    /// Reject one RPC while preserving the byte connection for recovery tests.
    func failResponse(to method: String, occurrence: Int) {
        failingResponseOccurrences[method, default: []].insert(occurrence)
    }

    /// Leave one RPC pending until caller cancellation or disconnect.
    func dropResponse(to method: String, occurrence: Int) {
        droppedResponseOccurrences[method, default: []].insert(occurrence)
    }

    /// Hold a response without blocking independent requests on the same connection.
    func holdResponse(to method: String, occurrence: Int) {
        heldResponseOccurrences[method, default: []].insert(occurrence)
    }

    /// Deliver the captured response after the test has established the competing operation.
    func releaseResponse(to method: String, occurrence: Int) {
        heldResponseOccurrences[method]?.remove(occurrence)
        if let response = heldResponses[method]?.removeValue(forKey: occurrence) {
            deliver(response)
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    /// Push one server event envelope to the client.
    func pushEvent(topic: String, payload: [String: Any]) {
        let envelope: [String: Any] = ["kind": "event", "topic": topic, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let framed = try? MobileSyncFrameCodec.encodeFrame(data) else { return }
        deliver(framed)
    }

    /// Simulate the connection dying host-side (EOF to the client's reader).
    func killConnection() {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    /// Suspend until the host has served `count` requests of `method`.
    func waitForMethod(_ method: String, count: Int = 1) async throws {
        guard sentMethods.filter({ $0 == method }).count < count else { return }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        methodWaiters[id] = MethodWaiter(method: method, count: count, continuation: continuation)
        defer {
            methodWaiters.removeValue(forKey: id)?.continuation.finish()
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in stream { return } }
            group.addTask {
                // A deadline bounds a broken test; it is not used to settle state.
                try await ContinuousClock().sleep(for: .seconds(5))
                throw WaitError.methodNotReceived(method)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    /// Deliver an event immediately after a chosen response, before client decoding can finish.
    func pushEventAfterResponse(
        to method: String,
        occurrence: Int,
        topic: String
    ) throws {
        let envelope: [String: Any] = [
            "kind": "event", "topic": topic, "payload": [:],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        responseEvents.append(ResponseEvent(
            method: method,
            occurrence: occurrence,
            frame: try MobileSyncFrameCodec.encodeFrame(data)
        ))
    }

    private func resolveMethodWaiters(method: String) {
        let count = sentMethods.filter { $0 == method }.count
        let matching = methodWaiters.filter { $0.value.method == method && $0.value.count <= count }
        for (id, waiter) in matching {
            methodWaiters.removeValue(forKey: id)
            waiter.continuation.yield(())
            waiter.continuation.finish()
        }
    }

    private func deliver(_ framed: Data) {
        if receiveWaiters.isEmpty {
            pendingResponses.append(framed)
        } else {
            let waiter = receiveWaiters.removeFirst()
            waiter.resume(returning: framed)
        }
    }
}

/// Factory handing out one shared scripted transport for every route.
struct ScriptedHostTransportFactory: CmxByteTransportFactory {
    let transport: ScriptedHostTransport

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        transport
    }
}
