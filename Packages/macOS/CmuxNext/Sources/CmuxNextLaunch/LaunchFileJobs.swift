public import CmuxNextWakeups

/// The file jobs the launch starts that nobody waits for, as posted ``BackgroundWork`` files-lane
/// jobs (p08-startup-083, Q12). At ``WorkPriority/idle`` and ``WorkPriority/bestEffort`` they wait
/// behind the launch's best-effort fence (``LaunchOrder/BestEffortFence``, raised in `main()` before
/// the delegate exists), so their disk writes do not compete with the first window; they run at
/// startup complete or at the fence's cap. Chrome posts such work with `TaskPriority::BEST_EFFORT`
/// and `MayBlock` to the thread pool, which `BeginBestEffortFence` holds during startup
/// (base/task/thread_pool/thread_pool_instance.h).
///
/// Each job keeps the QoS its `Task.detached` had: the design-mode cleanup `.background`
/// (``WorkPriority/idle``), the CLI pointer `.utility` (``WorkPriority/bestEffort``).
///
/// The work is injected, so tests post it on their own lanes.
///
/// ```swift
/// LaunchFileJobs(removeDesignModeTempFiles: { BrowserDesignModeController.tempFiles.removeAll() },
///                publishCLIPointer: isolated ? nil : { _ = LastAppCLIPointer().publish(cliPath: cli) })
///     .post(on: work)
/// ```
public struct LaunchFileJobs: Sendable {
    /// Deletes the design-mode files a crash left (`BrowserDesignModeTempFiles`).
    public let removeDesignModeTempFiles: @Sendable () -> Void
    /// Writes the last opened app's CLI pointer (`LastAppCLIPointer`); nil when this launch must
    /// not claim it (an isolated launch) or the bundle has no CLI.
    public let publishCLIPointer: (@Sendable () -> Void)?

    public init(removeDesignModeTempFiles: @escaping @Sendable () -> Void, publishCLIPointer: (@Sendable () -> Void)?) {
        self.removeDesignModeTempFiles = removeDesignModeTempFiles
        self.publishCLIPointer = publishCLIPointer
    }

    /// Posts each job once on `work`'s files lane and returns at once.
    public func post(on work: BackgroundWork) {
        work.post(.idle, mayBlock: .files, removeDesignModeTempFiles)
        if let publishCLIPointer { work.post(.bestEffort, mayBlock: .files, publishCLIPointer) }
    }
}
