/// The system's memory pressure, as the kernel's memory pressure source reports it
/// (``MemoryPressureEvents`` delivers each change; nothing polls).
///
/// The app's one pressure-level type: hibernation, the warm set budget and the debug socket's
/// `debug.hibernation.pressure` all speak it. The raw values are the names the socket and the logs use.
public enum MemoryPressureLevel: String, Hashable, Sendable, Codable {
    /// Normal memory use (again).
    case normal
    /// The kernel asks processes to free what they can spare.
    case warning
    /// The kernel is short of memory; free everything not on screen.
    case critical
}
