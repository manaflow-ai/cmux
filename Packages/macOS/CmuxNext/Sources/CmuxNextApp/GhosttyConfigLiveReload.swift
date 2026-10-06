import Foundation
import CmuxNextSettings
import CmuxNextTerminal

/// Keeps the applied Ghostty config synchronized with the files libghostty
/// actually loaded, including `config-file` includes and theme files.
@MainActor
final class GhosttyConfigLiveReload {
    private let files: @MainActor () -> [String]
    private let reload: @MainActor () -> Void
    private let notifications: NotificationCenter
    private var watchers: [ConfigFileWatcher] = []
    private var reloadTimer: DispatchSourceTimer?
    private var observer: (any NSObjectProtocol)?
    private var started = false

    init(
        files: @escaping @MainActor () -> [String] = { GhosttyRuntime.shared.liveReloadConfigFiles },
        reload: @escaping @MainActor () -> Void = { GhosttyRuntime.shared.reloadConfig() },
        notifications: NotificationCenter = .default
    ) {
        self.files = files
        self.reload = reload
        self.notifications = notifications
    }

    isolated deinit {
        reloadTimer?.cancel()
        if let observer { notifications.removeObserver(observer) }
        watchers.forEach { $0.stop() }
    }

    func start() {
        guard !started else { return }
        started = true
        observer = notifications.addObserver(forName: GhosttyRuntime.configDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rearm() }
        }
        rearm()
    }

    func stop() {
        started = false
        reloadTimer?.cancel()
        reloadTimer = nil
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
        guard started, reloadTimer == nil else { return }
        // Atomic saves touch the file and its include directory. Coalesce the
        // burst, then let libghostty resolve the complete latest file graph.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(75))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.reloadTimer?.cancel()
                self.reloadTimer = nil
                self.reload()
            }
        }
        reloadTimer = timer
        timer.resume()
    }
}
