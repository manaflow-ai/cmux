import CMUXMobileCore
import CmuxMobileRPC
import Foundation

actor HeldAuthorizationFailureGate {
    private var didReachHeldRequest = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReached() async {
        if didReachHeldRequest { return }
        await withCheckedContinuation { reachedWaiters.append($0) }
    }

    func holdUntilReleased() async {
        didReachHeldRequest = true
        let waiters = reachedWaiters
        reachedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

struct HeldAuthorizationFailureTransportFactory: CmxByteTransportFactory {
    let method: String
    let gate: HeldAuthorizationFailureGate
    let router: LivenessHostRouter

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        _ = route
        return HeldAuthorizationFailureTransport(method: method, gate: gate, router: router)
    }
}

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
