import CMUXMobileCore
import CmuxMobileRPC
import Foundation

actor HeldAuthorizationFailureTransport: CmxByteTransport {
    private let method: String
    private let gate: HeldAuthorizationFailureGate
    private let router: LivenessHostRouter
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(method: String, gate: HeldAuthorizationFailureGate, router: LivenessHostRouter) {
        self.method = method
        self.gate = gate
        self.router = router
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingFrames.isEmpty { return pendingFrames.removeFirst() }
        if isClosed { return nil }
        return await withCheckedContinuation { receiveWaiters.append($0) }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            let request = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let requestMethod = request?["method"] as? String
            let requestID = request?["id"] as? String
            let params = request?["params"] as? [String: Any]
            let topics = params?["topics"] as? [String]
            await router.record(method: requestMethod, topics: topics)
            Task { [method, gate, router, weak self] in
                let response: Data?
                if requestMethod == method {
                    await gate.holdUntilReleased()
                    response = try? Self.errorFrame(id: requestID, message: "Unauthorized")
                } else {
                    response = await router.response(method: requestMethod, id: requestID)
                }
                guard let response else { return }
                await self?.deliver(response)
            }
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    private func deliver(_ frame: Data) {
        if !receiveWaiters.isEmpty {
            receiveWaiters.removeFirst().resume(returning: frame)
        } else {
            pendingFrames.append(frame)
        }
    }

    private static func errorFrame(id: String?, message: String) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": false,
            "error": ["message": message],
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }
}
