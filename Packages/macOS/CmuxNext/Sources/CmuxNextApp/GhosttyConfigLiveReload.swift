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
    private let reloadTimer = DemandTimer(owner: "GhosttyConfigLiveReload.reload")
    private var watchers: [ConfigFileWatcher] = []
    private var started = false

    /// - Parameter onConfigChange: Registers a handler for every config change
    ///   (``GhosttyRuntime/addConfigChangeHandler(_:)``). A service: the loaded file graph can change
    ///   with any config change (a new `config-file` include, another theme), with or without a
    ///   terminal on screen; `rearm` does nothing while stopped.
    init(
        files: @escaping @MainActor () -> [String] = { GhosttyRuntime.shared.liveReloadConfigFiles },
        reload: @escaping @MainActor () -> Void = { GhosttyRuntime.shared.reloadConfig() },
        onConfigChange: @MainActor (@escaping @MainActor () -> Void) -> Void = { GhosttyRuntime.shared.addConfigChangeHandler($0) }
    ) {
        self.files = files
        self.reload = reload
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
        rearm()
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
        reloadTimer.scheduleOnMainIfIdle(after: .milliseconds(75)) { [weak self] in
            guard let self, self.started else { return }
            self.reload()
        }
    }
}
