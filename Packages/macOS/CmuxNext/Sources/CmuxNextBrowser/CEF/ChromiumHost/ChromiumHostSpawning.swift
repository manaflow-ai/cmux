#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
import Darwin

/// A started host: its pid and the wire the supervisor hands out.
nonisolated struct ChromiumHostSpawn: Sendable, Equatable {
    var pid: pid_t
    var attachment: ChromiumHostAttachment
    /// A host a crashed cmux started and this one adopted (task p01-process-150): not this process's child, so its
    /// end is watched without a status and it is never reaped here.
    var adopted = false
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

    /// Tries to adopt the host a crashed cmux left running (task p01-process-150), off the main thread.
    func adopt() async -> ChromiumHostAdoption.Outcome
    /// Watches a host this process did not start (an adopted one) off the main thread and runs `ended` on the main
    /// thread when it ends; its status cannot be read.
    func watchAdoptedExit(of pid: pid_t, _ ended: @escaping @MainActor @Sendable (ChromiumHostExit) -> Void)
    /// Returns once `pid`, a host this process did not start, has ended, or after `limit` (then it is SIGKILLed when
    /// it still runs this app's host executable).
    func awaitAdoptedEnd(of pid: pid_t, limit: Duration) async
    /// SIGKILL to an adopted `pid` when it still runs this app's host executable (it is no child: its pid may be reused).
    func killAdopted(_ pid: pid_t)
}

nonisolated extension ChromiumHostSpawning {
    // Stand-ins that start their own hosts adopt nothing.
    func adopt() async -> ChromiumHostAdoption.Outcome { .noHost("this spawner adopts no host") }
    func watchAdoptedExit(of pid: pid_t, _ ended: @escaping @MainActor @Sendable (ChromiumHostExit) -> Void) {
        watchExit(of: pid, ended)
    }
    func awaitAdoptedEnd(of pid: pid_t, limit: Duration) async {}
    func killAdopted(_ pid: pid_t) { kill(pid) }
}
#endif
