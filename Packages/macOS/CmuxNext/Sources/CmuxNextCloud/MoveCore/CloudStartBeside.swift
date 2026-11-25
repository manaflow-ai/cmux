public import Foundation

/// Work a Cloud start needs done before one later step, not before every step: it starts at once and runs beside
/// the steps in between, so it costs the start only the time it outlasts them. The first one is this Mac's model
/// gateway coming online (``PersonalGateway/onlineBeside(within:)``), which a start awaited before its approvals,
/// copy, tab and agent start although only the chat's first turn uses it: with the gateway not reachable that
/// was its whole 10 s deadline in the start's `approvals` step.
@MainActor public final class CloudStartBeside<Value: Sendable> {
    private let task: Task<Value, Never>

    public init(_ work: @escaping @MainActor @Sendable () async -> Value) {
        task = Task { await work() } // task-owner: CloudStartBeside: awaited before the step that needs it, cancelled when the start lets go of it
    }

    /// A start that ends before the step that needs the work (a failure, a cancellation) ends the work with it.
    nonisolated deinit { task.cancel() }

    /// What the work answered, once it has.
    public var value: Value { get async { await task.value } }

    /// What the work answered, and the time it ran past the steps beside it marked as the step `name` on `steps`
    /// (0 ms when it had finished first), so a start's `stages_ms` still shows a wait on it.
    public func awaited(marking name: String, on steps: CloudStartSteps) async -> Value {
        let value = await task.value
        steps.done(name)
        return value
    }

    /// ``awaited(marking:on:)`` when the step after it needs the work; when it does not, `name` is marked at once
    /// (0 ms) and the work goes on beside, unawaited (nil).
    public func awaited(marking name: String, on steps: CloudStartSteps, if needed: Bool) async -> Value? {
        guard needed else { steps.done(name); return nil }
        return await awaited(marking: name, on: steps)
    }
}

extension PersonalGateway {
    /// ``ensureOnline(within:)`` started now, beside a Cloud start's steps: its model calls reach this Mac's own gateway
    /// through its edge (no login step), and only the chat's first turn needs it up.
    public func onlineBeside(within deadline: Duration) -> CloudStartBeside<Bool> {
        CloudStartBeside { [self] in await ensureOnline(within: deadline) }
    }

    /// Whether a Cloud chat's first turn reaches the provider through this Mac's gateway, so its start waits for it.
    /// `credential`: the connection of this Mac's whose credential the chat's agent launches with
    /// (``CloudSetup/Choice/connectionID``). With one, the machine's agent calls the provider straight
    /// (``CloudAgentCredential``) and never this gateway: waiting for it only delayed the start, by up to its whole
    /// 10 s deadline while it came up (the production chat probe, 2026-11-15 to 22: 124 of 406 starts, about 2.4 s each).
    public nonisolated static func turnNeedsIt(credential: String?) -> Bool { credential == nil }
}
