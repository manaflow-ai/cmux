public import Foundation

/// Work a Cloud start needs done before one later step, not before every step: it starts at once and runs beside
/// the steps in between, so it costs the start only the time it outlasts them. The first one is this Mac's model
/// gateway coming online (``PersonalGateway/ensureOnline(within:)``), which a start awaited before its approvals,
/// copy, tab and agent start although only the chat's first turn uses it: with the gateway not reachable that
/// was its whole 10 s deadline in the start's `approvals` step.
@MainActor public struct CloudStartBeside<Value: Sendable> {
    private let task: Task<Value, Never>

    public init(_ work: @escaping @MainActor @Sendable () async -> Value) {
        task = Task { await work() } // task-owner: CloudStartBeside: awaited by `value` before the step that needs it, cancelled by `cancel()` on every other exit
    }

    /// What the work answered, once it has.
    public var value: Value { get async { await task.value } }

    /// What the work answered, and the time it ran past the steps beside it marked as the step `name` on `steps`
    /// (0 ms when it had finished first), so a start's `stages_ms` still shows a wait on it.
    public func awaited(marking name: String, on steps: CloudStartSteps) async -> Value {
        let value = await task.value
        steps.done(name)
        return value
    }

    /// Ends the work for a start that will not reach the step that needs it.
    public func cancel() { task.cancel() }
}
