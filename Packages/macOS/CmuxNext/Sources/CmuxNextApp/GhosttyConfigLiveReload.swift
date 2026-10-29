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
    private let makeWatcher: (URL, @escaping @Sendable () -> Void) -> ConfigFileWatcher
    private var watchers: [ConfigFileWatcher] = []
    /// The launch's watchers by path, marked at the launch call and armed after startup; nil when no launch arm is pending.
    private var launchMarks: [String: ConfigFileWatcher]?
    private var started = false

    /// - Parameters:
    ///   - deadlines: The app's deadline scheduler (`AppServices.mainDeadlines`): the reload debounce and each
    ///     file event's hop to main run on its scheduler.
    ///   - onConfigChange: Registers a handler for every config change
    ///     (``GhosttyRuntime/addConfigChangeHandler(_:)``). A service: the loaded file graph can change
    ///     with any config change (a new `config-file` include, another theme), with or without a
    ///     terminal on screen; `rearm` does nothing while stopped.
    ///   - makeWatcher: Makes the watcher of one file (tests pass one on a queue they can fence).
    init(
        deadlines: MainDeadlineScheduler,
        files: @escaping @MainActor () -> [String] = { GhosttyRuntime.shared.liveReloadConfigFiles },
        reload: @escaping @MainActor () -> Void = { GhosttyRuntime.shared.reloadConfig() },
        onConfigChange: @MainActor (@escaping @MainActor () -> Void) -> Void = { GhosttyRuntime.shared.addConfigChangeHandler($0) },
        makeWatcher: @escaping (URL, @escaping @Sendable () -> Void) -> ConfigFileWatcher = { ConfigFileWatcher(url: $0, onChange: $1) }
    ) {
        self.files = files
        self.reload = reload
        self.makeWatcher = makeWatcher
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

    func start() {
        guard !started else { return }
        started = true
        launchMarks = nil
        rearm()
    }

    /// Arms the watch after startup completes (Q13): nothing before it reads a config edit, as Chrome
    /// posts non-critical launch work (chrome/browser/after_startup_task_utils.cc). Each file's state is marked now, off
    /// main, and a file written, replaced, created or deleted since then reloads once when the watch arms.
    func startAfterStartup(on startup: StartupScheduler) {
        guard !started, launchMarks == nil else { return }
        var marks: [String: ConfigFileWatcher] = [:]
        for path in files() where marks[path] == nil {
            let watcher = newWatcher(for: path)
            watcher.mark()
            marks[path] = watcher
        }
        launchMarks = marks
        startup.post(.afterStartup, "GhosttyConfigLiveReload.start", on: .main) { [weak self] in self?.startFromLaunchMarks() }
    }

    func stop() {
        started = false
        launchMarks = nil
        reloadTimer.cancel()
        watchers.forEach { $0.stop() }
        watchers.removeAll()
    }

    private func startFromLaunchMarks() {
        guard !started, let marks = launchMarks else { return }
        started = true
        launchMarks = nil
        watchers = files().map { path in
            guard let watcher = marks[path] else {
                // A file the launch did not load (an include a launch reload added): read it once the watch exists.
                let fresh = newWatcher(for: path)
                fresh.start()
                return fresh
            }
            watcher.startFromMark()
            return watcher
        }
    }

    private func rearm() {
        guard started else { return }
        watchers.forEach { $0.stop() }
        watchers = files().map { path in
            let watcher = newWatcher(for: path)
            watcher.start(reportInitialChange: false)
            return watcher
        }
    }

    private func newWatcher(for path: String) -> ConfigFileWatcher {
        makeWatcher(URL(fileURLWithPath: path)) { [weak self, mainWork] in
            mainWork.postFromAnyThread(.visible, owner: "GhosttyConfigLiveReload.fileChanged") { [weak self] in self?.requestReload() }
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
