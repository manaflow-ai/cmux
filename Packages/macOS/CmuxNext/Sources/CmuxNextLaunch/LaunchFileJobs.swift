public import CmuxNextWakeups

/// The file jobs the launch starts that nobody waits for, as posted ``BackgroundWork`` files-lane
/// jobs (Q12), instead of root `Task.detached` jobs on the cooperative pool.
///
/// - The design-mode cleanup is ``WorkPriority/idle`` (QoS `.background`, as before), so it waits
///   behind the launch's best-effort fence (``LaunchOrder/BestEffortFence``, raised in `main()`) and
///   runs at the launch's reveal; quit drops it if it has not started (the next launch
///   redoes it). It deletes only earlier launches' folders, so it is safe whenever it runs.
/// - The CLI pointer is ``WorkPriority/userVisible`` and ``ShutdownBehavior/blockShutdown``: the
///   fence does not hold it, because a script that opens the app and runs `cmux` at once must get this
///   app's CLI (plans/cmux-next/version-skew.md: the app writes it at launch), and a quit during
///   startup still waits for its one atomic replace.
///
/// Chrome posts the first with `TaskPriority::BEST_EFFORT` and `MayBlock`, which
/// `BeginBestEffortFence` holds during startup (base/task/thread_pool/thread_pool_instance.h), and the
/// second with `TaskShutdownBehavior::BLOCK_SHUTDOWN` (base/task/task_traits.h).
///
/// The work is injected, so tests post it on their own lanes.
///
/// ```swift
/// LaunchFileJobs(removeDesignModeTempFiles: { BrowserDesignModeController.tempFiles.removeEarlierLaunches() },
///                publishCLIPointer: isolated ? nil : { _ = LastAppCLIPointer().publish(cliPath: cli) })
///     .post(on: work)
/// ```
public struct LaunchFileJobs: Sendable {
    /// Deletes the design-mode files earlier launches left (`BrowserDesignModeTempFiles`).
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
        if let publishCLIPointer { work.post(.userVisible, mayBlock: .files, shutdown: .blockShutdown, publishCLIPointer) }
    }
}
