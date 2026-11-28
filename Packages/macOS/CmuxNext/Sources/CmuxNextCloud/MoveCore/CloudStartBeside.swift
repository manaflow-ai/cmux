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

    /// ``onlineBeside(within:)`` for a start whose model route may not use this gateway: `route` (the start's
    /// ``CloudSetup/choose(harness:model:account:)``) is asked first, and when ``servedElsewhere(_:)`` says another
    /// gateway or key serves it the start waits for no gateway (true at once). A chat on its own connection or the
    /// organization's key never needed it, yet a gateway that could not come up held such a start for its whole
    /// deadline. On by default; the kill switch ``gatewaySkipOffKey`` (`defaults write <app id>
    /// cmux.cloud.gatewaySkip.off -bool YES`) brings the wait back.
    public func onlineBeside(within deadline: Duration, route: @escaping @MainActor @Sendable () async -> CloudSetup.Choice) -> CloudStartBeside<Bool> {
        let skipOff = UserDefaults.standard.bool(forKey: Self.gatewaySkipOffKey)
        return CloudStartBeside { [self] in
            if !skipOff, servedElsewhere(await route()) { return true }
            return await ensureOnline(within: deadline)
        }
    }

    /// Whether a start on `choice` has its first turn served without this Mac's gateway coming up: its connection's
    /// credential or the organization's key (``CloudSetup/Choice/servedWithoutMacGateway``), or the team's gateway
    /// when that is another one of the person's that took over from this one (``State/replaced``). `choice` read that
    /// gateway online just now (``CloudSetup/Choice/gateway(family:)``), so it serves the turn. Taking it back here
    /// cost every such start its restart: cloud-chat-replies-production's gateway rows, whose own team gateway served
    /// the turn (2 to 9 calls), waited 2.5 to 4.4 s in their `gateway` step on this one's restart (2026-11-25 19:40Z to
    /// 2026-11-26 00:54Z), and the restart took the machines from the gateway serving them.
    /// The same holds while this one is still starting or dialing: `choice` read the team's gateway online and serving now
    /// (`serves` is empty when it is off or offline), and this Mac's is not online, so another gateway serves the turn.
    /// Waiting for this one cost the production probe's first start after sign-in its whole 10 s deadline (run
    /// 45965760313, 2026-11-27 12:19Z: `gateway` 3479 ms after the other steps, select to first text 17.9 s, the team's
    /// gateway serving both model calls).
    public func servedElsewhere(_ choice: CloudSetup.Choice) -> Bool {
        if choice.servedWithoutMacGateway { return true }
        if case .gateway = choice, state != .online { return true } // online: ensureOnline answers at once anyway
        return false
    }

    /// The kill switch for the gateway skip above: set, every start waits for this Mac's gateway as before.
    public nonisolated static let gatewaySkipOffKey = "cmux.cloud.gatewaySkip.off"
}
