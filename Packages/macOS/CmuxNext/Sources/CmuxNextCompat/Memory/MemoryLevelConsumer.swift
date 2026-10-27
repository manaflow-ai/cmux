/// A lossy ``MemoryConsumer`` that paces its own release by the pressure level, such as a discard
/// planner: the registry hands it each level it acts on, the debug override included.
///
/// A ``MemoryLimit`` tells a lossy consumer only whether pressure is critical (Chrome's urgent page
/// discarding policy acts when `memory_limit() <= CriticalPressureThreshold`). cmux's browser
/// hibernation also has a warning pace (p07-memory.md section 3.A keeps it until task 075 measures
/// how often macOS reports warning), so it needs the level itself. It gets it from its registration,
/// not from a second subscription to the kernel's pressure source.
///
/// The registry calls ``memoryLevelDidChange(_:)`` with the current level before the registration's
/// init returns, then on each change of level, in the same turn as the new limits.
@MainActor
public protocol MemoryLevelConsumer: MemoryConsumer {
    /// Takes the pressure level the registry acts on now.
    ///
    /// - Parameter level: The debug override when set, else the kernel's level.
    func memoryLevelDidChange(_ level: MemoryPressureLevel)
}
