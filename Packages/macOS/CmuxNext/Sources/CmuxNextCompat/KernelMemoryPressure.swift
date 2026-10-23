/// The kernel's memory pressure level, as ``MemoryPressureEvents`` delivers it.
public enum KernelMemoryPressure: Sendable, Hashable {
    /// The kernel reports normal memory use again.
    case normal
    /// The kernel asks processes to free what they can spare.
    case warning
    /// The kernel is short of memory; free everything not on screen.
    case critical
}
