import Foundation

/// Seam for system command execution so UI/tests can inject a fake instead of
/// mutating the real machine. Async so callers never block a thread on a slow
/// command or the admin prompt.
///
/// Every requirement is `nonisolated`: implementations do process and
/// filesystem work that must stay off the main actor, and conformers are plain
/// `Sendable` types rather than actors.
protocol SleepyCommandRunning: Sendable {
    /// Fire-and-forget (e.g. `pmset displaysleepnow`).
    ///
    /// - Parameters:
    ///   - tool: Absolute path of the executable.
    ///   - args: Arguments passed to the executable.
    /// - Returns: `false` when the tool could not be launched at all (missing
    ///   binary, not executable). Callers use this to fall back to another
    ///   mechanism instead of silently doing nothing — a missing system tool is
    ///   exactly how the Sleepy Mode lock button broke on macOS 26.
    @discardableResult nonisolated func run(_ tool: String, _ args: [String]) async -> Bool
    /// Whether `tool` exists and is executable, so a caller can choose between
    /// mechanisms by capability rather than by guessing at an OS version.
    ///
    /// - Parameter tool: Absolute path to probe.
    /// - Returns: `true` when the file can be executed.
    nonisolated func canRun(_ tool: String) async -> Bool
    /// Runs `tool` and waits for it to exit, reporting `true` only on a zero
    /// exit status.
    ///
    /// Use this where the caller must know the action actually happened rather
    /// than merely that the process started — locking the screen must not be
    /// reported as successful just because the binary launched.
    ///
    /// - Parameters:
    ///   - tool: Absolute path of the executable.
    ///   - args: Arguments passed to the executable.
    /// - Returns: `true` only on a zero exit status.
    @discardableResult nonisolated func runAwaitingExit(_ tool: String, _ args: [String]) async -> Bool
    /// Run and capture stdout (e.g. `pmset -g`). No privileges.
    ///
    /// - Parameters:
    ///   - tool: Absolute path of the executable.
    ///   - args: Arguments passed to the executable.
    /// - Returns: Captured stdout, or `nil` when the tool could not run.
    nonisolated func capture(_ tool: String, _ args: [String]) async -> String?
    /// Run a privileged tool via Authorization Services, awaiting its exit.
    ///
    /// - Parameters:
    ///   - tool: Absolute path of the executable.
    ///   - args: Arguments passed to the executable.
    /// - Returns: `true` when the tool ran and exited successfully.
    @discardableResult nonisolated func runPrivileged(_ tool: String, _ args: [String]) async -> Bool
    /// Engages the macOS login lock in-process, for systems where the supported
    /// command-line tool no longer ships.
    ///
    /// - Returns: `false` when no lock mechanism is available.
    @discardableResult nonisolated func lockScreen() async -> Bool
}
