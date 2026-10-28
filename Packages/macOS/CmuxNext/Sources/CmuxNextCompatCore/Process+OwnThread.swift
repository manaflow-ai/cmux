public import Foundation

extension Process {
    /// Starts a process, like `run()`, on a new thread of its own at `qos`, and returns at once.
    ///
    /// For a process without CmuxNextWakeups' `ProcessLauncher` (the privileged server helper, which links
    /// this module and not CmuxNextCompat): the spawn, a fork and exec that takes hundreds of
    /// ms under memory pressure, never runs on the caller's thread or on Swift's cooperative pool.
    /// Chromium launches children the same way, on a launcher thread of its own, never the UI thread
    /// (content/browser/child_process_launcher_helper.cc). The child runs at `qos` too.
    ///
    /// `child` makes and configures the process (pipes, `terminationHandler` set) on the new thread;
    /// it captures the process's Sendable owner, never a `Process`. Only that thread touches the
    /// process, so an owner that must stop the child records the pid `launched` reports and signals
    /// that pid, never the `Process`. Once the spawn runs, the termination handler reports
    /// the exit. When the spawn fails, `failed` runs on that thread and neither `launched` nor the
    /// termination handler runs.
    ///
    /// ```swift
    /// Process.runOnOwnThread(qos: .utility, name: "cmux.server-helper.fix", { [self] in makeProcess() },
    ///                        launched: { [self] pid in record(pid) }, failed: { error in fail(error) })
    /// ```
    ///
    /// - Parameters:
    ///   - qos: The thread's and the child's quality of service (never `.userInteractive`).
    ///   - name: The thread's name (it shows in samples and traces).
    ///   - child: Makes and returns the process to start, on the new thread.
    ///   - launched: Runs with the child's pid on that thread right after the spawn.
    ///   - failed: Runs with the launch error when the process cannot start.
    public static func runOnOwnThread(qos: QualityOfService, name: String, _ child: @escaping @Sendable () -> Process,
                                      launched: @escaping @Sendable (Int32) -> Void,
                                      failed: @escaping @Sendable (any Error) -> Void) {
        let thread = Thread {
            let process = child()
            process.qualityOfService = qos
            do {
                // blocking-allow: the spawn runs on this thread of its own, made for it; nothing else waits on it.
                try process.run()
            } catch {
                return failed(error)
            }
            launched(process.processIdentifier)
        }
        thread.name = name
        thread.qualityOfService = qos
        thread.start()
    }
}
