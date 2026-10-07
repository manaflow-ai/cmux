import CmuxNextAgentPane
import CmuxNextSettings
import Foundation

/// Watches the agent pane customization files (`theme.css`, `layout.json`,
/// `registry.js` in the `agent-pane` directory next to `cmux.json`) and
/// reports each change on the main actor. Every save style (in place, atomic
/// rename, delete and recreate, the directory appearing later) counts; the
/// files are read off the main actor and an unchanged result is dropped.
final class AgentPaneCustomizationWatcher {
    /// The latest files read, empty until the first read completes.
    private(set) var current = AgentPaneCustomization()
    /// Called on the main actor with each new value.
    var onChange: ((AgentPaneCustomization) -> Void)?

    private let directory: URL
    private var watchers: [ConfigFileWatcher] = []
    private var reloadTask: Task<Void, Never>?
    private var reloadRequested = false

    init(directory: URL) {
        self.directory = directory
    }

    /// Arms the watch and reads the files once. Does nothing while running.
    func start() {
        guard watchers.isEmpty else { return }
        watchers = AgentPaneCustomization.fileNames.map { name in
            ConfigFileWatcher(url: directory.appending(path: name)) { [weak self] in
                Task { @MainActor in self?.requestReload() }
            }
        }
        for watcher in watchers { watcher.start() }
    }

    /// Stops watching; ``current`` keeps the last value read.
    func stop() {
        for watcher in watchers { watcher.stop() }
        watchers = []
        reloadTask?.cancel()
        reloadTask = nil
        reloadRequested = false
    }

    private func requestReload() {
        guard !watchers.isEmpty else { return }
        reloadRequested = true
        guard reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            while let directory = self?.takeReloadRequest() {
                let value = await Self.read(directory)
                if Task.isCancelled { return }
                self?.apply(value)
            }
            self?.reloadTask = nil
        }
    }

    /// The directory to read when a reload is pending, clearing it.
    private func takeReloadRequest() -> URL? {
        guard reloadRequested else { return nil }
        reloadRequested = false
        return directory
    }

    private func apply(_ value: AgentPaneCustomization) {
        guard value != current else { return }
        current = value
        onChange?(value)
    }

    @concurrent private static func read(_ directory: URL) async -> AgentPaneCustomization {
        AgentPaneCustomization(directory: directory)
    }
}
