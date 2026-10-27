public import CmuxNextCompat

/// The coordinator's value observers: its vote in in-process Chromium's pressure aggregator, and its debug
/// override.
extension MemoryCoordinator {
    public func observePressureVote(_ handler: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void)
        -> MainActorHandlerRegistration<MemoryPressureLevel> {
        voteHandlers.add(handler)
    }

    /// Calls `handler` with each change of ``pressureOverride``, after that change's level consumers; also a
    /// change that leaves ``level`` as it was (an override equal to the kernel's level, set or cleared), which
    /// reaches no ``MemoryLevelConsumer``.
    ///
    /// - Parameter handler: Main-actor work for each new override (nil: cleared).
    /// - Returns: The registration; keep it in a stored property.
    public func observePressureOverride(_ handler: @escaping @MainActor @Sendable (MemoryPressureLevel?) -> Void)
        -> MainActorHandlerRegistration<MemoryPressureLevel?> {
        overrideHandlers.add(handler)
    }
}
