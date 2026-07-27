public import Foundation

/// A thread-safe, one-shot bridge from an asynchronous Web Inspector operation to a socket request.
///
/// `@unchecked Sendable` is safe because `condition` protects every access to
/// the mutable `completion` value, and completion accepts only the first result.
public final class ControlSimulatorWebInspectorReceipt: @unchecked Sendable {
    private let condition = NSCondition()
    private let readinessTimeout: TimeInterval?
    private let cancellationJoinTimeout: TimeInterval
    private var completion: ControlSimulatorWebInspectorCompletion?
    private var cancellation: (@Sendable () -> Void)?
    private var operationIsReady = false

    /// Creates an unresolved receipt.
    public init(
        readinessTimeout: TimeInterval? = nil,
        cancellationJoinTimeout: TimeInterval = 5
    ) {
        self.readinessTimeout = readinessTimeout.map { max(0, $0) }
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

    /// Starts the operation-specific deadline after pane readiness completes.
    public func markOperationReady() {
        condition.lock()
        defer { condition.unlock() }
        guard completion == nil else { return }
        operationIsReady = true
        condition.broadcast()
    }

    /// Waits through the optional readiness phase, then gives the actual Web
    /// Inspector operation its full timeout.
    public func wait(timeout: TimeInterval) -> ControlSimulatorWebInspectorCompletion? {
        condition.lock()
        if let readinessTimeout {
            let readinessDeadline = Date().addingTimeInterval(readinessTimeout)
            while completion == nil, !operationIsReady {
                guard condition.wait(until: readinessDeadline) else { break }
            }
        }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while completion == nil, readinessTimeout == nil || operationIsReady {
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
