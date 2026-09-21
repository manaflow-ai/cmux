#if os(iOS)
/// Serializes empty-state recovery operations. A timed-out UI wait can release
/// its button without allowing a cancellation-ignoring refresh to overlap the
/// next attempt.
actor MobileWorkspaceRetryGate {
    private var active: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        if let active {
            await active.value
        }
        let task = Task { await operation() }
        active = task
        await task.value
        active = nil
    }
}
#endif
