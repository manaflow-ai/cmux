import CMUXMobileCore
import CmuxMobileRPC
import Foundation

actor RecordedAuthLivenessTransport: CmxByteTransport {
    private let router: LivenessHostRouter
    private let tokenSink: RecordedAuthTokenSink
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(router: LivenessHostRouter, tokenSink: RecordedAuthTokenSink) {
        self.router = router
        self.tokenSink = tokenSink
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
            let auth = request?["auth"] as? [String: Any]
            await tokenSink.record(auth?["stack_access_token"] as? String)
            await router.record(method: requestMethod, topics: topics)
            Task { [router, weak self] in
                guard let response = await router.response(method: requestMethod, id: requestID) else {
                    return
                }
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
}
