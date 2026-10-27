import Foundation
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextWakeups

/// Keeps the applied Ghostty config synchronized with the files libghostty
/// actually loaded, including `config-file` includes and theme files.
@MainActor
final class GhosttyConfigLiveReload {
    private let files: @MainActor () -> [String]
    private let reload: @MainActor () -> Void
    /// Coalesces a save's burst of file events into one reload. `visible`: terminals repaint with the new config.
    private let reloadTimer: MainDeadline
    private let mainWork: MainWorkScheduler
    private var watchers: [ConfigFileWatcher] = []
    private var started = false

    /// - Parameters:
    ///   - deadlines: The app's deadline scheduler (`AppServices.mainDeadlines`): the reload debounce and each
    ///     file event's hop to main run on its scheduler.
    ///   - onConfigChange: Registers a handler for every config change
    ///     (``GhosttyRuntime/addConfigChangeHandler(_:)``). A service: the loaded file graph can change
    ///     with any config change (a new `config-file` include, another theme), with or without a
    ///     terminal on screen; `rearm` does nothing while stopped.
    init(
        deadlines: MainDeadlineScheduler,
        files: @escaping @MainActor () -> [String] = { GhosttyRuntime.shared.liveReloadConfigFiles },
        reload: @escaping @MainActor () -> Void = { GhosttyRuntime.shared.reloadConfig() },
        onConfigChange: @MainActor (@escaping @MainActor () -> Void) -> Void = { GhosttyRuntime.shared.addConfigChangeHandler($0) }
    ) {
        self.files = files
        self.reload = reload
        (reloadTimer, mainWork) = (MainDeadline(owner: "GhosttyConfigLiveReload.reload", workClass: .visible, scheduler: deadlines), deadlines.work)
        onConfigChange { [weak self] in self?.rearm() }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            reloadTimer.cancel()
            watchers.forEach { $0.stop() }
        }
    }

    /// Arms the watch; with `since`, a save made at or after it, before the watch existed, reloads once.
    func start(changedSince since: ConfigFileWatcher.Since? = nil) {
        guard !started else { return }
        started = true
        rearm(changedSince: since)
    }

    /// Arms the watch after startup completes (Q13, p08-startup-086): nothing before it reads a config edit, as Chrome
    /// posts non-critical launch work (chrome/browser/after_startup_task_utils.cc). A save since this call reloads once.
    func startAfterStartup(on startup: StartupScheduler) {
        let since = ConfigFileWatcher.Since.now
        startup.post(.afterStartup, "GhosttyConfigLiveReload.start", on: .main) { [weak self] in self?.start(changedSince: since) }
    }

    func stop() {
        started = false
        reloadTimer.cancel()
        watchers.forEach { $0.stop() }
        watchers.removeAll()
    }

    private func rearm(changedSince since: ConfigFileWatcher.Since? = nil) {
        guard started else { return }
        watchers.forEach { $0.stop() }
        watchers = files().map { path in
            let watcher = ConfigFileWatcher(url: URL(fileURLWithPath: path)) { [weak self, mainWork] in
                mainWork.postFromAnyThread(.visible, owner: "GhosttyConfigLiveReload.fileChanged") { [weak self] in self?.requestReload() }
            }
            if let since { watcher.start(changedSince: since) } else { watcher.start(reportInitialChange: false) }
            return watcher
        }
    }

    private func requestReload() {
        guard started, !reloadTimer.isScheduled else { return }
        // Atomic saves touch the file and its include directory. Coalesce the
        // burst, then let libghostty resolve the complete latest file graph.
        reloadTimer.scheduleIfIdle(after: .milliseconds(75)) { [weak self] in
            guard let self, self.started else { return }
            self.reload()
        }
    }
}
