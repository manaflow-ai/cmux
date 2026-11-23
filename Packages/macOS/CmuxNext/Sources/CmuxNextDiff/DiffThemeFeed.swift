import CmuxNextCompat
public import CmuxNextSettings
public import Foundation

/// The user's diff viewer stylesheet, `<dir of cmux.json>/diff/theme.css` (customization.md D55,
/// rule 4), the way the agent pane and the file pages load theirs: read off the main actor,
/// watched while any tab listens (every save style, the folder appearing later), and pushed to
/// every listener on a change (the page's `cmux.diff.theme` stream), "" once the file is gone.
/// The page applies it as its last `<style>` (webviews/src/diff/page.ts `startPageDiffTheme`).
public final class DiffThemeFeed {
    /// A stylesheet larger than this is not one: the page gets "" instead.
    nonisolated static let fileLimit = 2 * 1024 * 1024

    public let file: URL
    private var current: String?
    private var listeners: [UUID: @MainActor (String) -> Void] = [:]
    private var watcher: ConfigFileWatcher?
    private var reload: Task<Void, Never>?
    private var pending = false

    public init(file: URL) {
        self.file = file
    }

    public static func stylesheet(configFile: URL) -> URL {
        configFile.deletingLastPathComponent().appending(path: "diff/theme.css", directoryHint: .notDirectory)
    }

    /// The stylesheet now (read once on first use).
    func css() async -> String {
        if let current { return current }
        let text = await Self.read(file)
        if current == nil { current = text }
        return current ?? text
    }

    /// Calls `onChange` with every later stylesheet until the returned cancel runs.
    public func listen(_ onChange: @escaping @MainActor (String) -> Void) -> () -> Void {
        let id = UUID()
        let starting = listeners.isEmpty
        listeners[id] = onChange
        if starting { startWatching() }
        return { [weak self] in
            guard let self else { return }
            listeners[id] = nil
            if listeners.isEmpty { stopWatching() }
        }
    }

    var listenerCount: Int { listeners.count }
    /// Whether the file is watched now (tests).
    var isWatching: Bool { watcher != nil }

    private func startWatching() {
        let watcher = ConfigFileWatcher(url: file) { [weak self] in
            // task-owner: one hop to the main actor per file event; requestReload owns the read
            // main-hop-allow: a file watch's kernel event, not an action's work: the hop only marks a reload pending (the read runs off the main actor) and bursts coalesce into one read
            Task { @MainActor in self?.requestReload() }
        }
        self.watcher = watcher
        // The initial report reads the file once the watch exists, so a save between a tab's
        // `cmux.diff.theme` answer and its subscription still reaches it.
        watcher.start()
    }

    private func stopWatching() {
        watcher?.stop()
        watcher = nil
        reload?.cancel()
        reload = nil
        pending = false
    }

    private func requestReload() {
        guard watcher != nil else { return }
        pending = true
        guard reload == nil else { return }
        reload = Task { [weak self] in
            while let file = self?.takePending() {
                let text = await Self.read(file)
                if Task.isCancelled { return }
                self?.apply(text)
            }
            self?.reload = nil
        }
    }

    private func takePending() -> URL? {
        guard pending else { return nil }
        pending = false
        return file
    }

    private func apply(_ text: String) {
        guard text != current else { return }
        let first = current == nil
        current = text
        // The first read only fills the cache: no tab has seen another value.
        guard !first else { return }
        for id in listeners.keys.sorted(by: { $0.uuidString < $1.uuidString }) { listeners[id]?(text) }
    }

    @concurrent private static func read(_ file: URL) async -> String {
        // concurrency-allow: @concurrent, off the main actor
        let target = file.resolvingSymlinksInPath()
        // concurrency-allow: @concurrent, off the main actor
        guard let size = (try? target.blockingResourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= fileLimit else { return "" }
        // concurrency-allow: @concurrent, off the main actor
        return (try? String(blockingContentsOf: target, encoding: .utf8)) ?? ""
    }
}
