import CMUXMobileCore
import Foundation
@testable import CmuxMobileRPC

/// A control transport whose stream goes silent on a connection that can
/// still carry a replacement stream. Every request written before a repair is
/// swallowed, like a stalled QUIC stream. `repairOutcome` is what the
/// connection-level evidence would conclude.
actor RepairableSilentTransport: CmxByteTransportControlStreamRepairing {
    struct SentRequest: Equatable {
        let id: String
        let method: String
        let generation: UInt64
    }

    private let repairOutcome: CmxControlStreamRepairOutcome
    private let replacementAnswers: Bool
    private var generation: UInt64 = 0
    private var sent: [SentRequest] = []
    private var queuedFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var sendCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var isClosed = false
    private(set) var repairCount = 0

    /// - Parameters:
    ///   - repairOutcome: What a repair attempt concludes.
    ///   - replacementAnswers: Whether the host answers requests written to a
    ///     replacement stream. `false` models a host whose application layer
    ///     acknowledged the new stream but never serves it.
    init(repairOutcome: CmxControlStreamRepairOutcome, replacementAnswers: Bool = true) {
        self.repairOutcome = repairOutcome
        self.replacementAnswers = replacementAnswers
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !queuedFrames.isEmpty { return queuedFrames.removeFirst() }
        if isClosed { return nil }
        return await withCheckedContinuation { receiveWaiters.append($0) }
    }

    func send(_ data: Data) async throws {
        _ = try await sendReportingControlStreamGeneration(data)
    }

    func sendReportingControlStreamGeneration(_ data: Data) async throws -> UInt64 {
        guard !isClosed else { throw MobileShellConnectionError.connectionClosed }
        var buffer = data
        for payload in try MobileSyncFrameCodec.decodeFrames(from: &buffer) {
            let request = try recordedRPCRequest(from: payload)
            let id = request.id ?? ""
            sent.append(SentRequest(id: id, method: request.method ?? "", generation: generation))
            if generation > 0, replacementAnswers {
                try deliverResponse(id: id)
            }
        }
        let ready = sendCountWaiters.filter { sent.count >= $0.0 }
        sendCountWaiters.removeAll { sent.count >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        return generation
    }

    func repairControlStream(
        silentSince: ContinuousClock.Instant
    ) async -> CmxControlStreamRepairOutcome {
        repairCount += 1
        guard !isClosed else { return .connectionSilent }
        if case .repaired = repairOutcome {
            generation += 1
            return .repaired(generation: generation)
        }
        return repairOutcome
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    func closed() -> Bool { isClosed }

    func sentRequests() -> [SentRequest] { sent }

    func waitUntilSent(count: Int) async {
        if sent.count >= count { return }
        await withCheckedContinuation { sendCountWaiters.append((count, $0)) }
    }

    /// Polls for teardown, which runs after the timed-out request has already
    /// been failed back to its caller.
    func waitUntilClosed(within limit: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !isClosed, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return isClosed
    }

    private func deliverResponse(id: String) throws {
        let response: [String: Any] = ["id": id, "ok": true, "result": ["status": "ok"]]
        let frame = try MobileSyncFrameCodec.encodeFrame(
            JSONSerialization.data(withJSONObject: response)
        )
        if let waiter = receiveWaiters.first {
            receiveWaiters.removeFirst()
            waiter.resume(returning: frame)
        } else {
            queuedFrames.append(frame)
        }
    }
}
