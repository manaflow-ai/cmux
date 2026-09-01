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
    /// since macOS 26 removed `CGSession`). Returns only after the public lock
    /// state confirms the transition or the bounded confirmation deadline is
    /// reached; cancellation ends an unconfirmed request without claiming that
    /// the Mac was locked.
    @discardableResult
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func lockScreen() async -> Bool

    /// Same operation with lifecycle cancellation serialized against the
    /// irreversible loginwindow invocation.
    @discardableResult
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func lockScreen(using gate: SleepyLockInvocationGate) async -> Bool
}

extension SleepyCommandRunning {
    /// Default so command-recording fakes stay compiling and inert: locking is
    /// reported unavailable unless a conformer (the real
    /// `SystemCommandRunner`) explicitly provides the system effect.
    @discardableResult
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func lockScreen() async -> Bool { false }

    @discardableResult
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func lockScreen(using gate: SleepyLockInvocationGate) async -> Bool {
        guard gate.invoke({}) else { return false }
        return await lockScreen()
    }
}
