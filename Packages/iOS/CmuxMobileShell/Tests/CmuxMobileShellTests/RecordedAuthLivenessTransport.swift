import CMUXMobileCore
import CmuxMobileRPC
import Foundation

actor RecordedAuthTokenSink {
    private var tokens: [String] = []

    func record(_ token: String?) {
        guard let token else { return }
        tokens.append(token)
    }

    func recordedTokens() -> [String] { tokens }
}

struct RecordedAuthLivenessTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let tokenSink: RecordedAuthTokenSink

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        _ = route
        return RecordedAuthLivenessTransport(router: router, tokenSink: tokenSink)
    }
}

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

actor BlockingAccountSwitchTokenProvider {
    private var didEnter = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var token = "user-a-token"

    func waitUntilRequested() async {
        if didEnter { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func tokenIgnoringCancellation() async throws -> String {
        didEnter = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
        return token
    }

    func release(with token: String) {
        self.token = token
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
