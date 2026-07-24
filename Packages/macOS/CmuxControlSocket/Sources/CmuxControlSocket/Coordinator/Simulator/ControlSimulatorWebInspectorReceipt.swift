public import Foundation

/// A thread-safe, one-shot bridge from an asynchronous Web Inspector operation to a socket request.
///
/// `@unchecked Sendable` is safe because `condition` protects every access to
/// the mutable `completion` value, and completion accepts only the first result.
public final class ControlSimulatorWebInspectorReceipt: @unchecked Sendable {
    private let condition = NSCondition()
    private let cancellationJoinTimeout: TimeInterval
    private var completion: ControlSimulatorWebInspectorCompletion?
    private var cancellation: (@Sendable () -> Void)?

    /// Creates an unresolved receipt.
    public init(cancellationJoinTimeout: TimeInterval = 5) {
        self.cancellationJoinTimeout = max(0, cancellationJoinTimeout)
    }

    /// Resolves the receipt once and wakes every waiter.
    public func complete(_ completion: ControlSimulatorWebInspectorCompletion) {
        condition.lock()
        defer { condition.unlock() }
        guard self.completion == nil else { return }
        self.completion = completion
        cancellation = nil
        condition.broadcast()
    }

    /// Installs cancellation for the asynchronous inspector operation.
    public func installCancellation(_ cancellation: @escaping @Sendable () -> Void) {
        condition.lock()
        defer { condition.unlock() }
        guard completion == nil else { return }
        self.cancellation = cancellation
    }

    /// Waits until the receipt resolves or the timeout expires.
    public func wait(timeout: TimeInterval) -> ControlSimulatorWebInspectorCompletion? {
        condition.lock()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while completion == nil {
            guard condition.wait(until: deadline) else { break }
        }
        let result = completion
        let cancellation = result == nil ? self.cancellation : nil
        if result == nil { self.cancellation = nil }
        condition.unlock()
        cancellation?()
        guard result == nil, cancellation != nil, cancellationJoinTimeout > 0 else {
            return result
        }
        condition.lock()
        let unwindDeadline = Date().addingTimeInterval(cancellationJoinTimeout)
        while completion == nil {
            guard condition.wait(until: unwindDeadline) else { break }
        }
        let joinedResult: ControlSimulatorWebInspectorCompletion?
        if case .failed? = completion {
            joinedResult = nil
        } else {
            joinedResult = completion
        }
        condition.unlock()
        return joinedResult
    }
}
