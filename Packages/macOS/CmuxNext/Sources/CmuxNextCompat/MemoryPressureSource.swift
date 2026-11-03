/// Where ``MemoryPressureEvents`` gets the memory pressure level: the kernel's dispatch source in the
/// app (``KernelMemoryPressureSource``, made at the composition root), a fake that a test drives.
///
/// ```swift
/// let events = MemoryPressureEvents(source: KernelMemoryPressureSource())
/// ```
public protocol MemoryPressureSource: Sendable {
    /// Starts calling `deliver` on the main actor with each new level, until ``cancel()``.
    ///
    /// ``MemoryPressureEvents`` calls it once, from its init.
    ///
    /// - Parameter deliver: Main-actor work for each level the source reports.
    func start(delivering deliver: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void)

    /// Stops the calls (any thread; ``MemoryPressureEvents`` calls it from its deinit).
    func cancel()
}
