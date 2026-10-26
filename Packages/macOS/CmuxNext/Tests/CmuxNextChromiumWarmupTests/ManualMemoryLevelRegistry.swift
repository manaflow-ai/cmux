import CmuxNextCompat

/// A memory consumer registry the test drives, as the app's memory coordinator behaves for lossy
/// consumers: a new consumer gets the current limit and level at once, and ``send(_:)`` hands each
/// live ``MemoryLevelConsumer`` a new level (nothing for a repeated one, nothing after its
/// registration is cancelled).
@MainActor
final class ManualMemoryLevelRegistry: MemoryConsumerRegistry {
    private(set) var level = MemoryPressureLevel.normal
    private var entries: [MemoryConsumerEntry] = []

    func addMemoryConsumer(_ entry: MemoryConsumerEntry) {
        entries.removeAll { !$0.isLive }
        entries.append(entry)
        entry.liveConsumer?.updateMemoryLimit(.default)
        (entry.liveConsumer as? any MemoryLevelConsumer)?.memoryLevelDidChange(level)
    }

    /// Delivers `level` to every live level consumer, as a kernel or override change would.
    func send(_ newLevel: MemoryPressureLevel) {
        guard newLevel != level else { return }
        level = newLevel
        for entry in entries {
            (entry.liveConsumer as? any MemoryLevelConsumer)?.memoryLevelDidChange(newLevel)
        }
    }

    /// How many registrations are still live.
    var liveCount: Int {
        entries.filter(\.isLive).count
    }
}
