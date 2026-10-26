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
    /// Ends the launch's in-memory config files (``GhosttyRuntime/endLaunchConfig()``) once the watch starts,
    /// and says what the launch read.
    private let endLaunch: @MainActor () -> GhosttyRuntime.LaunchConfig?
    /// Asks whether the files the launch read changed on the disk since (``GhosttyConfigFiles/changed(reader:)``)
    /// off the main thread, and answers on a later main turn.
    private let checkLaunchFiles: @MainActor (GhosttyConfigFiles, @escaping @MainActor @Sendable (Bool) -> Void) -> Void
    private let reloadTimer = DemandTimer(owner: "GhosttyConfigLiveReload.reload")
    private var watchers: [ConfigFileWatcher] = []
    private var started = false

    /// - Parameters:
    ///   - files: The files to watch.
    ///   - reload: Reloads the config from the disk.
    ///   - endLaunch: Ends the launch's config files and says what the launch read.
    ///   - checkLaunchFiles: Whether the launch's files changed on the disk, answered later; it never blocks the main thread.
    ///   - onConfigChange: Registers a handler for every config change
    ///     (``GhosttyRuntime/addConfigChangeHandler(_:)``). A service: the loaded file graph can change
    ///     with any config change (a new `config-file` include, another theme), with or without a
    ///     terminal on screen; `rearm` does nothing while stopped.
    init(
        files: @escaping @MainActor () -> [String],
        reload: @escaping @MainActor () -> Void,
        endLaunch: @escaping @MainActor () -> GhosttyRuntime.LaunchConfig?,
        checkLaunchFiles: @escaping @MainActor (GhosttyConfigFiles, @escaping @MainActor @Sendable (Bool) -> Void) -> Void,
        onConfigChange: @MainActor (@escaping @MainActor () -> Void) -> Void
    ) {
        self.files = files
        self.reload = reload
        self.endLaunch = endLaunch
        self.checkLaunchFiles = checkLaunchFiles
        onConfigChange { [weak self] in self?.rearm() }
    }

    /// The app's live reload of the terminal runtime's config: the launch check stats the files on `work`'s files
    /// lane and answers in `mainWork`'s visible class.
    convenience init(runtime: GhosttyRuntime, work: BackgroundWork, mainWork: MainWorkScheduler) {
        self.init(files: { runtime.liveReloadConfigFiles }, reload: { runtime.reloadConfig() },
                  endLaunch: { runtime.endLaunchConfig() },
                  checkLaunchFiles: { files, answer in
                      work.run(.userVisible, mayBlock: .files) { files.changed() }
                          .reply(on: mainWork, class: .visible, owner: "ghostty.configLaunchCheck") { answer($0) }
                  },
                  onConfigChange: { runtime.addConfigChangeHandler($0) })
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            reloadTimer.cancel()
            watchers.forEach { $0.stop() }
        }
    }

    /// ``start()`` right after the first frame (p08-startup-026): until then the launch's loads use the
    /// config files read in `main`, and no file is watched.
    func start(after startup: StartupScheduler) {
        startup.post(.afterFirstFrame, "Ghostty.configLiveReload", on: .main) { [weak self] in self?.start() }
    }

    func start() {
        guard !started else { return }
        started = true
        // From the watch on, every load reads the disk, so a change it reports is loaded.
        let launch = endLaunch()
        rearm()
        // A save between the launch's read and the watch armed above reported nothing: compare the launch's
        // files with the disk now, and reload once when one changed. The disk path read in the launch turn,
        // with no stamps to compare, so it reloads once.
        switch launch {
        case .memory(let files):
            checkLaunchFiles(files) { [weak self] changed in
                guard changed, let self, self.started else { return }
                self.reload()
            }
        case .disk: reload()
        case nil: break
        }
    }

    func stop() {
        started = false
        reloadTimer.cancel()
        watchers.forEach { $0.stop() }
        watchers.removeAll()
    }

    private func rearm() {
        guard started else { return }
        watchers.forEach { $0.stop() }
        watchers = files().map { path in
            let watcher = ConfigFileWatcher(url: URL(fileURLWithPath: path)) { [weak self] in
                Task { @MainActor in self?.requestReload() }
            }
            watcher.start(reportInitialChange: false)
            return watcher
        }
    }

    private func requestReload() {
        guard started, !reloadTimer.isScheduled else { return }
        // Atomic saves touch the file and its include directory. Coalesce the
        // burst, then let libghostty resolve the complete latest file graph.
        reloadTimer.scheduleIfIdle(after: .milliseconds(75)) { @MainActor [weak self] in
            guard let self, self.started else { return }
            self.reload()
        }
    }
}
