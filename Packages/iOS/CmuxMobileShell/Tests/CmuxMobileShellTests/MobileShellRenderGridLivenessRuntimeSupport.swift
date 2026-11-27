import CMUXMobileCore
import CmuxMobileRPC
import Foundation
@testable import CmuxMobileShell

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()

    var now: Date {
        lock.withLock { current }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

struct LivenessTestRuntime: MobileSyncRuntime {
    var transportFactory: any CmxByteTransportFactory
    var stackAccessTokenProvider: @Sendable () async throws -> String = { "test-stack-token" }
    var stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "test-stack-token" }
    var rpcRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var now: @Sendable () -> Date
    var supportedRouteKinds: [CmxAttachTransportKind] = [.debugLoopback]
    var pairingRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var pairingAttemptTimeoutNanoseconds: UInt64 = 8 * 1_000_000_000
    var supportsServerPushEvents: Bool = true
    var livenessProbeTimeoutNanoseconds: UInt64 = 200_000_000
    var reconnectAttemptDeadlineNanoseconds: UInt64 = 30 * 1_000_000_000
    /// Virtual reconnect-deadline clock; `nil` uses real time.
    var reconnectDeadlineGate: ReconnectDeadlineGate?
    var macDialDeadlineNanoseconds: UInt64 = 8 * 1_000_000_000
    /// Virtual per-Mac dial-deadline clock; `nil` uses real time.
    var macDialDeadlineGate: ReconnectDeadlineGate?

    func sleepUntilReconnectAttemptDeadline(nanoseconds: UInt64) async throws {
        if let reconnectDeadlineGate {
            try await reconnectDeadlineGate.sleep()
        } else {
            try await RPCTaskTimeout.continuousClockSleep(nanoseconds: nanoseconds)
        }
    }

    func sleepUntilMacDialDeadline(nanoseconds: UInt64) async throws {
        if let macDialDeadlineGate {
            try await macDialDeadlineGate.sleep()
        } else {
            try await RPCTaskTimeout.continuousClockSleep(nanoseconds: nanoseconds)
        }
    }
}

/// Virtual clock for reconnect-attempt deadlines: each deadline stays pending
/// until the test expires it, and a deadline whose attempt settles first is
/// cancelled and dropped. Tests order deadline expiry against real events
/// instead of against wall-clock time.
final class ReconnectDeadlineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var armed = 0

    var pendingCount: Int { lock.withLock { pending.count } }
    /// Deadlines ever armed, including settled and expired ones.
    var armedCount: Int { lock.withLock { armed } }

    func sleep() async throws {
        let id = UUID()
        lock.withLock { armed += 1 }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let alreadyCancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    pending[id] = continuation
                    return false
                }
                if alreadyCancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = lock.withLock { pending.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Expires every deadline currently pending.
    func expirePending() {
        let expired = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        for continuation in expired { continuation.resume() }
    }
}
