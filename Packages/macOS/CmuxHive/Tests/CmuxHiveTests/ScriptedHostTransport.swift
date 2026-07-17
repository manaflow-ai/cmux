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
    private(set) var sentMethods: [String] = []
    private(set) var sentInputTexts: [String] = []
    private var methodWaiters: [(method: String, continuation: CheckedContinuation<Void, Never>)] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func connect() async throws {
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
            let result = handler(method, params)
            let envelope: [String: Any] = ["id": id, "ok": true, "result": result]
            if let payload = try? JSONSerialization.data(withJSONObject: envelope),
               let framed = try? MobileSyncFrameCodec.encodeFrame(payload) {
                deliver(framed)
            }
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
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    /// Suspend until the host has served `count` requests of `method`.
    func waitForMethod(_ method: String, count: Int = 1) async {
        while sentMethods.filter({ $0 == method }).count < count {
            await withCheckedContinuation { continuation in
                methodWaiters.append((method, continuation))
            }
        }
    }

    private func resolveMethodWaiters(method: String) {
        let matching = methodWaiters.filter { $0.method == method }
        methodWaiters.removeAll { $0.method == method }
        for waiter in matching {
            waiter.continuation.resume()
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
