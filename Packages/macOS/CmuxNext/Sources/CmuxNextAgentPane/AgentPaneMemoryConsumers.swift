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
    /// How the coordinator's calls reach the project icons' actor.
    let hop: AsyncMemoryConsumerHop
    let frames: AgentPaneNewTabFrame
    let tails: AgentPaneTailCache
    let icons: AgentPaneProjectIcons

    /// The app's caches (each one's `shared`).
    ///
    /// - Parameters:
    ///   - registry: The app's memory coordinator (AppServices+Memory.swift).
    ///   - hop: How the coordinator's calls reach the icons' actor (``AsyncMemoryConsumerHop/task`` in the app).
    public init(registry: any MemoryConsumerRegistry, hop: AsyncMemoryConsumerHop = .task) {
        self.init(registry: registry, hop: hop, frames: .shared, tails: .shared, icons: .shared)
    }

    /// Caches of a test's own.
    init(registry: any MemoryConsumerRegistry, hop: AsyncMemoryConsumerHop, frames: AgentPaneNewTabFrame,
         tails: AgentPaneTailCache, icons: AgentPaneProjectIcons) {
        self.registry = registry
        self.hop = hop
        self.frames = frames
        self.tails = tails
        self.icons = icons
    }

    /// Registers the frames, tails and icons, replacing an earlier registration of each.
    public func register() {
        frames.registerMemoryConsumer(with: registry)
        tails.registerMemoryConsumer(with: registry)
        icons.registerMemoryConsumer(with: registry, hop: hop)
    }
}
