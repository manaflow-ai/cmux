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
    /// Whether the files the launch read changed on the disk since (``GhosttyConfigFiles/changed(reader:)``),
    /// asked off the main thread.
    private let launchFilesChanged: @MainActor (GhosttyConfigFiles) async -> Bool
    private let notifications: NotificationCenter
    private let reloadTimer = DemandTimer(owner: "GhosttyConfigLiveReload.reload")
    private var watchers: [ConfigFileWatcher] = []
    private var observer: (any NSObjectProtocol)?
    private var started = false
    /// The check of the launch's config files against the disk, once the watch is armed (tests await it).
    private(set) var launchCheck: Task<Void, Never>?

    /// - Parameters:
    ///   - files: The files to watch.
    ///   - reload: Reloads the config from the disk.
    ///   - endLaunch: Ends the launch's config files and says what the launch read.
    ///   - launchFilesChanged: Whether the launch's files changed on the disk; it must not block the main thread.
    ///   - notifications: Where ``GhosttyRuntime/configDidChange`` is posted.
    init(
        files: @escaping @MainActor () -> [String],
        reload: @escaping @MainActor () -> Void,
        endLaunch: @escaping @MainActor () -> GhosttyRuntime.LaunchConfig?,
        launchFilesChanged: @escaping @MainActor (GhosttyConfigFiles) async -> Bool,
        notifications: NotificationCenter = .default
    ) {
        self.files = files
        self.reload = reload
        self.endLaunch = endLaunch
        self.launchFilesChanged = launchFilesChanged
        self.notifications = notifications
    }

    /// The app's live reload of the terminal runtime's config; the launch check reads the disk on `work`'s files lane.
    convenience init(runtime: GhosttyRuntime, work: BackgroundWork) {
        self.init(files: { runtime.liveReloadConfigFiles }, reload: { runtime.reloadConfig() },
                  endLaunch: { runtime.endLaunchConfig() },
                  launchFilesChanged: { files in
                      (try? await work.run(.userVisible, mayBlock: .files) { files.changed() }) ?? false
                  })
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            reloadTimer.cancel()
            if let observer { notifications.removeObserver(observer) }
            watchers.forEach { $0.stop() }
            launchCheck?.cancel()
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
        observer = notifications.addObserver(forName: GhosttyRuntime.configDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rearm() }
        }
        rearm()
        // A save between the launch's read and the watch armed above reported nothing: compare the launch's
        // files with the disk now, and reload once when one changed. The disk path read in the launch turn,
        // with no stamps to compare, so it reloads once.
        switch launch {
        case .memory(let files):
            launchCheck = Task { [weak self, launchFilesChanged] in
                guard await launchFilesChanged(files), let self, self.started else { return }
                self.reload()
            }
        case .disk: reload()
        case nil: break
        }
    }

    func stop() {
        started = false
        launchCheck?.cancel()
        reloadTimer.cancel()
        watchers.forEach { $0.stop() }
        watchers.removeAll()
        if let observer {
            notifications.removeObserver(observer)
            self.observer = nil
        }
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
