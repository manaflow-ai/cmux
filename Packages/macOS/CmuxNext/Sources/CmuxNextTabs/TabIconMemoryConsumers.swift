public import CmuxNextCompat

/// The tab strips' drawn icon caches in the app's memory coordinator: tinted symbols, icon pack images,
/// agent marks, user emoji and known symbol names. Each cache's ``TabImageMemo`` keeps its own
/// registration, so the coordinator calls it while the cache lives. The hover card thumbnails register with
/// each strip (`attachHoverCards`).
///
/// ```swift
/// TabIconMemoryConsumers(registry: memoryCoordinator).register()
/// ```
public struct TabIconMemoryConsumers {
    /// The app's memory coordinator.
    public let registry: any MemoryConsumerRegistry
    let symbols: TabSymbolCache
    let packIcons: TabPackIconCache
    let agentMarks: TabAgentMarkCache
    let userIcons: TabUserIconImages

    /// The strips' caches (each one's `shared`).
    ///
    /// - Parameter registry: The app's memory coordinator (AppServices+Memory.swift).
    public init(registry: any MemoryConsumerRegistry) {
        self.init(registry: registry, symbols: .shared, packIcons: .shared, agentMarks: .shared, userIcons: .shared)
    }

    /// Caches of a test's own.
    init(registry: any MemoryConsumerRegistry, symbols: TabSymbolCache, packIcons: TabPackIconCache,
         agentMarks: TabAgentMarkCache, userIcons: TabUserIconImages) {
        self.registry = registry
        self.symbols = symbols
        self.packIcons = packIcons
        self.agentMarks = agentMarks
        self.userIcons = userIcons
    }

    /// Registers every cache, replacing an earlier registration of each.
    public func register() {
        symbols.images.registerMemoryConsumer(with: registry)
        packIcons.images.registerMemoryConsumer(with: registry)
        agentMarks.images.registerMemoryConsumer(with: registry)
        userIcons.emojiImages.registerMemoryConsumer(with: registry)
        userIcons.symbolNames.registerMemoryConsumer(with: registry)
    }
}
