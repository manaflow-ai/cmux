/// Why a terminal surface has no live runtime to read from or write to.
public enum TerminalSurfaceRuntimeUnavailableReason: String, Sendable, CaseIterable {
    /// Teardown has begun or finished; the surface never starts again.
    case closing
    /// Agent Hibernation suspended the idle agent to save memory. The
    /// terminal stays suspended until it is shown again.
    case hibernated
    /// cmux restored the terminal after relaunch and is still checking which
    /// agent session to resume. The terminal starts by itself afterwards.
    case awaitingRestore = "awaiting_restore"
    /// The terminal may start, but its runtime is not running yet.
    case starting
}
