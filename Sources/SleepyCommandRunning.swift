import Foundation

/// Seam for system command execution so UI/tests can inject a fake instead of
/// mutating the real machine. Async so callers never block a thread on a slow
/// command or the admin prompt.
protocol SleepyCommandRunning: Sendable {
    /// Fire-and-forget (e.g. `pmset displaysleepnow`).
    ///
    /// - Returns: `false` when the tool could not be launched at all (missing
    ///   binary, not executable). Callers use this to fall back to another
    ///   mechanism instead of silently doing nothing — a missing system tool is
    ///   exactly how the Sleepy Mode lock button broke on macOS 26.
    @discardableResult func run(_ tool: String, _ args: [String]) async -> Bool
    /// Whether `tool` exists and is executable, so a caller can choose between
    /// mechanisms by capability rather than by guessing at an OS version.
    func canRun(_ tool: String) async -> Bool
    /// Run and capture stdout (e.g. `pmset -g`). No privileges.
    func capture(_ tool: String, _ args: [String]) async -> String?
    /// Run a privileged tool via Authorization Services, awaiting its exit.
    @discardableResult func runPrivileged(_ tool: String, _ args: [String]) async -> Bool
    /// Engages the macOS login lock in-process, for systems where the supported
    /// command-line tool no longer ships.
    ///
    /// - Returns: `false` when no lock mechanism is available.
    @discardableResult func lockScreen() async -> Bool
}
