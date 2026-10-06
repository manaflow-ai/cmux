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
    private var reloadTask: Task<Void, Never>?
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
        reloadTask?.cancel()
        if let observer { notifications.removeObserver(observer) }
        watchers.forEach { $0.stop() }
    }

    func start() {
        guard !started else { return }
        started = true
        observer = notifications.addObserver(forName: GhosttyRuntime.configDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rearm() }
        }
        rearm()
    }

    func stop() {
        started = false
        reloadTask?.cancel()
        reloadTask = nil
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
        guard started, reloadTask == nil else { return }
        // Atomic saves touch the file and its include directory. Coalesce the
        // burst, then let libghostty resolve the complete latest file graph.
        reloadTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(75)) } catch { return }
            guard let self, self.started else { return }
            self.reloadTask = nil
            self.reload()
        }
    }
}
