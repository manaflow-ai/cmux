#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
import Darwin

/// A started host: its pid and the wire the supervisor hands out.
nonisolated struct ChromiumHostSpawn: Sendable {
    var pid: pid_t
    var attachment: ChromiumHostAttachment
}

/// Starts and ends the supervisor's hosts; a seam so tests start a stand-in.
nonisolated protocol ChromiumHostSpawning: Sendable {
    /// Starts a host off the main thread and returns its pid and wire.
    func spawn() async throws(ChromiumHostAttachError) -> ChromiumHostSpawn
    /// Watches `pid` off the main thread (``ChromiumHostLaunching/exit(of:)``: it stays a zombie, not reaped) and runs
    /// `ended` with its exit on the main thread, posted in a stated class.
    func watchExit(of pid: pid_t, _ ended: @escaping @MainActor @Sendable (ChromiumHostExit) -> Void)
    /// Reaps an ended `pid`.
    func reap(_ pid: pid_t)
    /// SIGKILL to `pid`, a host this spawner started and nobody reaped yet.
    func kill(_ pid: pid_t)
}
#endif
