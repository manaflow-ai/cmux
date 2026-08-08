import Foundation

/// Seam for system command execution so UI/tests can inject a fake instead of
/// mutating the real machine. Async so callers never block a thread on a slow
/// command or the admin prompt.
protocol SleepyCommandRunning: Sendable {
    /// Fire-and-forget (e.g. `pmset displaysleepnow`).
    func run(_ tool: String, _ args: [String]) async
    /// Run and capture stdout (e.g. `pmset -g`). No privileges.
    func capture(_ tool: String, _ args: [String]) async -> String?
    /// Run a privileged tool via Authorization Services, awaiting its exit.
    @discardableResult func runPrivileged(_ tool: String, _ args: [String]) async -> Bool
    /// Engage the macOS login lock in-process (no subprocess exists for this
    /// since macOS 26 removed `CGSession`). Returns whether the lock call was
    /// available and reported success.
    @discardableResult func lockScreen() async -> Bool
}

extension SleepyCommandRunning {
    /// Default so command-recording fakes stay compiling and inert: locking is
    /// reported unavailable unless a conformer (the real
    /// `SystemCommandRunner`) explicitly provides the system effect.
    @discardableResult func lockScreen() async -> Bool { false }
}
