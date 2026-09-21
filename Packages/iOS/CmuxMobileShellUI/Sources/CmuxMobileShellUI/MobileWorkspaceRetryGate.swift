#if os(iOS)
/// Serializes empty-state recovery operations. A timed-out UI wait can release
/// its button without allowing a cancellation-ignoring refresh to overlap the
/// next attempt.
actor MobileWorkspaceRetryGate {
    private var active: Task<Void, Never>?
    private var activeID: UUID?

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        while true {
            guard !Task.isCancelled else { return }
            if let active {
                await active.value
                guard !Task.isCancelled else { return }
                continue
            }

            let operationID = UUID()
            let task = Task { [self] in
                await operation()
                await finish(operationID)
            }
            activeID = operationID
            active = task
            await task.value
            return
        }
    }

    private func finish(_ operationID: UUID) {
        guard activeID == operationID else { return }
        active = nil
        activeID = nil
    }
}
#endif
