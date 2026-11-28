import CMUXMobileCore
import Foundation
@testable import CmuxMobileRPC

actor CancellationIgnoringConnectTransport: CmxByteTransport {
    private var sentPayloads: [Data] = []
    private var connectWaiters: [CheckedContinuation<Void, Never>] = []
    private var connects = 0
    private var closes = 0

    func connect() async throws {
        connects += 1
        await withCheckedContinuation { continuation in
            connectWaiters.append(continuation)
        }
    }

    func receive() async throws -> Data? {
        nil
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        sentPayloads.append(contentsOf: payloads)
    }

    func close() async {
        closes += 1
    }

    func connectCount() -> Int {
        connects
    }

    func waitUntilConnectCount(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if connects >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return connects >= count
    }

    func closeCount() -> Int {
        closes
    }

    func releaseConnects() {
        let waiters = connectWaiters
        connectWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilCloseCount(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if closes >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return closes >= count
    }

    func sentRequests() throws -> [RecordedRPCRequest] {
        try sentPayloads.map(recordedRPCRequest(from:))
    }
}
