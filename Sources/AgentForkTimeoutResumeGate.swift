import CmuxFoundation
import Foundation

/// Narrow synchronous gate for timer/task races around a single continuation.
/// @unchecked Sendable: `continuation` is immutable after init, and
/// `didResume` atomically admits exactly one caller before the continuation is
/// resumed.
final class AgentForkTimeoutResumeGate<Value>: @unchecked Sendable {
    private let didResume = AtomicBooleanGate(false)
    private let continuation: CheckedContinuation<Value, Never>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: Value) -> Bool {
        guard didResume.compareExchange(expected: false, desired: true) else {
            return false
        }
        continuation.resume(returning: value)
        return true
    }
}
