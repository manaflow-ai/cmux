public import CmuxNextCompat

/// A memory consumer registry that stays at normal pressure: each consumer gets the default limit
/// and the normal level when it registers, and nothing after. For tests of a ``WebUIHost`` that do
/// not drive memory pressure; a test of the pressure path uses the app's coordinator over a source it
/// drives instead.
///
/// ```swift
/// let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: .testing())
/// ```
@MainActor
public final class QuietMemoryRegistry: MemoryConsumerRegistry {
    public init() {}

    public func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
        entry.liveConsumer?.updateMemoryLimit(.default)
        (entry.liveConsumer as? any MemoryLevelConsumer)?.memoryLevelDidChange(.normal)
    }
}
