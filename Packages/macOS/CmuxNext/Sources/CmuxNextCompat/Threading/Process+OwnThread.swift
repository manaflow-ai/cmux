public import Foundation

extension Process {
    /// Starts a process, like `run()`, on a new thread of its own at `qos`, and returns at once.
    ///
    /// For a process without CmuxNextWakeups' `ProcessLauncher` (the privileged server helper links
    /// only this file and `Mutex.swift` of Compat): the spawn, a fork and exec that takes hundreds of
    /// ms under memory pressure, never runs on the caller's thread or on Swift's cooperative pool.
    /// Chromium launches children the same way, on a launcher thread of its own, never the UI thread
    /// (content/browser/child_process_launcher_helper.cc). The child runs at `qos` too.
    ///
    /// `child` hands the configured process (pipes, `terminationHandler` set) to the thread; it
    /// captures the process's Sendable owner, never the process itself. Once the spawn runs, the
    /// termination handler reports the exit. When the spawn fails, `failed` runs on that thread and
    /// the termination handler never runs.
    ///
    /// ```swift
    /// Process.runOnOwnThread(qos: .utility, name: "cmux.server-helper.fix", { [self] in process }) { error in
    ///     fail(error)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - qos: The thread's and the child's quality of service (never `.userInteractive`).
    ///   - name: The thread's name (it shows in samples and traces).
    ///   - child: Returns the process to start, on the new thread.
    ///   - failed: Runs with the launch error when the process cannot start.
    public static func runOnOwnThread(qos: QualityOfService, name: String, _ child: @escaping @Sendable () -> Process,
                                      failed: @escaping @Sendable (any Error) -> Void) {
        let thread = Thread {
            let process = child()
            process.qualityOfService = qos
            do { try process.run() } catch { failed(error) }
        }
        thread.name = name
        thread.qualityOfService = qos
        thread.start()
    }
}
