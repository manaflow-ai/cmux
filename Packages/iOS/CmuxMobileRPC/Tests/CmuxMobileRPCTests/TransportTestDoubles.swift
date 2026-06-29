import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileRPC

/// A minimal `MobileSyncRuntime` for tests, supplying a transport factory,
/// stack-token provider, timeout, and clock without pulling the app's DI bundle.
struct TestMobileSyncRuntime: MobileSyncRuntime {
    var supportedRouteKinds: [CmxAttachTransportKind]
    var transportFactory: any CmxByteTransportFactory
    var stackAccessTokenProvider: @Sendable () async throws -> String
    var stackAccessTokenForStatusProvider: @Sendable () async -> String?
    var stackAccessTokenForceRefresher: @Sendable () async throws -> String
    var rpcRequestTimeoutNanoseconds: UInt64
    var pairingRequestTimeoutNanoseconds: UInt64
    var now: @Sendable () -> Date
    var supportsServerPushEvents: Bool

    init(
        transportFactory: any CmxByteTransportFactory,
        supportedRouteKinds: [CmxAttachTransportKind] = [.tailscale, .iroh, .websocket, .debugLoopback],
        stackAccessToken: String? = "test-stack-token",
        stackAccessTokenForStatus: String? = nil,
        stackAccessTokenProvider: (@Sendable () async throws -> String)? = nil,
        stackAccessTokenForStatusProvider: (@Sendable () async -> String?)? = nil,
        rpcRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000,
        pairingRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000,
        now: @escaping @Sendable () -> Date = Date.init,
        supportsServerPushEvents: Bool = true
    ) {
        self.supportedRouteKinds = supportedRouteKinds
        self.transportFactory = transportFactory
        self.stackAccessTokenProvider = stackAccessTokenProvider ?? {
            guard let stackAccessToken else { throw MissingTestStackAccessToken() }
            return stackAccessToken
        }
        self.stackAccessTokenForStatusProvider = stackAccessTokenForStatusProvider ?? {
            stackAccessTokenForStatus
        }
        self.stackAccessTokenForceRefresher = {
            guard let stackAccessToken else { throw MissingTestStackAccessToken() }
            return stackAccessToken
        }
        self.rpcRequestTimeoutNanoseconds = rpcRequestTimeoutNanoseconds
        self.pairingRequestTimeoutNanoseconds = pairingRequestTimeoutNanoseconds
        self.now = now
        self.supportsServerPushEvents = supportsServerPushEvents
    }
}

struct MissingTestStackAccessToken: Error {}

/// Async-safe one-shot boolean flag used to observe task progress in tests.
actor AsyncFlag {
    private var value = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set() {
        value = true
        let waiters = waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func isSet() -> Bool {
        value
    }

    func wait() async {
        if value {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

actor AsyncReleaseGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

/// A parsed snapshot of one RPC request frame for test assertions.
struct RecordedRPCRequest: Sendable {
    var id: String?
    var method: String?
    var workspaceID: String?
    var terminalID: String?
    var ticketRef: String?
    var text: String?
    var hasAuth: Bool
    var attachToken: String?
    var stackAccessToken: String?
}

func recordedRPCRequest(from payload: Data) throws -> RecordedRPCRequest {
    let request = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let params = request["params"] as? [String: Any] ?? [:]
    let auth = request["auth"] as? [String: Any]
    return RecordedRPCRequest(
        id: request["id"] as? String,
        method: request["method"] as? String,
        workspaceID: params["workspace_id"] as? String,
        terminalID: params["terminal_id"] as? String ?? params["surface_id"] as? String,
        ticketRef: params["ticket_ref"] as? String,
        text: params["text"] as? String,
        hasAuth: auth != nil,
        attachToken: auth?["attach_token"] as? String,
        stackAccessToken: auth?["stack_access_token"] as? String
    )
}

func hostPortRoute(
    kind: CmxAttachTransportKind,
    host: String,
    port: Int,
    priority: Int = 0
) throws -> CmxAttachRoute {
    try CmxAttachRoute(
        id: kind.rawValue,
        kind: kind,
        endpoint: .hostPort(host: host, port: port),
        priority: priority
    )
}

/// Transport that blocks its first `send` until released, recording payloads so
/// tests can assert a cancelled queued request is never written.
actor QueuedCancellationProbeTransport: CmxByteTransport {
    private var sentPayloads: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var firstSendRelease: CheckedContinuation<Void, Never>?
    private var shouldBlockFirstSend = true
    private var isClosed = false

    func connect() async throws {}

    func receive() async throws -> Data? {
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        sentPayloads.append(contentsOf: payloads)
        if shouldBlockFirstSend {
            shouldBlockFirstSend = false
            await withCheckedContinuation { continuation in
                firstSendRelease = continuation
            }
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
        releaseFirstSend()
    }

    func closed() -> Bool {
        isClosed
    }

    func releaseFirstSend() {
        firstSendRelease?.resume()
        firstSendRelease = nil
    }

    func sentRequests() throws -> [RecordedRPCRequest] {
        try sentPayloads.map(recordedRPCRequest(from:))
    }

    func waitForSentRequestCount(_ count: Int) async throws -> [RecordedRPCRequest] {
        var requests: [RecordedRPCRequest] = []
        for _ in 0..<200 {
            requests = try sentRequests()
            if requests.count >= count {
                return requests
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return requests
    }
}

struct QueuedCancellationProbeTransportFactory: CmxByteTransportFactory {
    let transport: QueuedCancellationProbeTransport

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        transport
    }
}
