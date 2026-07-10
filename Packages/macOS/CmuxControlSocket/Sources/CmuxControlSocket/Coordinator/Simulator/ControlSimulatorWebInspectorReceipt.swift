public import Foundation

/// A thread-safe, one-shot bridge from an asynchronous Web Inspector operation to a socket request.
///
/// `@unchecked Sendable` is safe because `condition` protects every access to
/// the mutable `completion` value, and completion accepts only the first result.
public final class ControlSimulatorWebInspectorReceipt: @unchecked Sendable {
    private let condition = NSCondition()
    private var completion: ControlSimulatorWebInspectorCompletion?

    /// Creates an unresolved receipt.
    public init() {}

    /// Resolves the receipt once and wakes every waiter.
    public func complete(_ completion: ControlSimulatorWebInspectorCompletion) {
        condition.lock()
        defer { condition.unlock() }
        guard self.completion == nil else { return }
        self.completion = completion
        condition.broadcast()
    }

    /// Waits until the receipt resolves or the timeout expires.
    public func wait(timeout: TimeInterval) -> ControlSimulatorWebInspectorCompletion? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while completion == nil {
            guard condition.wait(until: deadline) else { break }
        }
        return completion
    }
}
