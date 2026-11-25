import CMUXMobileCore
import Foundation
@testable import CmuxMobileRPC

/// Transport whose connect never finishes until `close()` is called, used to
/// prove request timeouts tear down pre-installation connection work.
actor SlowConnectTimeoutTransport: CmxByteTransport {
    private var sentPayloads: [Data] = []
    private var connectWaiter: CheckedContinuation<Void, Never>?
    private var connectStarted = false
    private var isClosed = false

    func connect() async throws {
        connectStarted = true
        if isClosed {
            throw CancellationError()
        }
        await withCheckedContinuation { continuation in
            if isClosed {
                continuation.resume()
            } else {
                connectWaiter = continuation
            }
        }
        throw CancellationError()
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
        isClosed = true
        connectWaiter?.resume()
        connectWaiter = nil
    }

    func waitUntilClosed() async -> Bool {
        for _ in 0..<200 {
            if isClosed {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return isClosed
    }

    func waitUntilConnectStarted() async -> Bool {
        for _ in 0..<200 {
            if connectStarted {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return connectStarted
    }

    func sentRequests() throws -> [RecordedRPCRequest] {
        try sentPayloads.map(recordedRPCRequest(from:))
    }
}
