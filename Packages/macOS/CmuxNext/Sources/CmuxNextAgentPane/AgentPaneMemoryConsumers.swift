public import CmuxNextCompat

/// The agent pane's caches in the app's memory coordinator: the New Tab page frames and the chat
/// tails on the main actor, the project icons on their own actor. Each cache keeps its own
/// registration, so the coordinator calls it while it lives.
///
/// ```swift
/// AgentPaneMemoryConsumers(registry: memoryCoordinator).register()
/// ```
public struct AgentPaneMemoryConsumers {
    /// The app's memory coordinator.
    public let registry: any MemoryConsumerRegistry

    /// - Parameter registry: The app's memory coordinator (AppServices+Memory.swift).
    public init(registry: any MemoryConsumerRegistry) {
        self.registry = registry
    }

    /// Registers the frames, tails and icons, replacing an earlier registration of each.
    public func register() {
        AgentPaneNewTabFrame.shared.registerMemoryConsumer(with: registry)
        AgentPaneTailCache.shared.registerMemoryConsumer(with: registry)
        AgentPaneProjectIcons.shared.registerMemoryConsumer(with: registry)
    }
}
