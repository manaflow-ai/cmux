import CmuxNextSettings
import Foundation

/// The user's diff viewer language pack, read the way the page dev host reads
/// it (webviews/dev-server/diffLanguages.ts): every `*.json` file directly in
/// `<dir of cmux.json>/diff/languages` and one level of subfolders, by name,
/// hidden entries skipped, symlinks followed only to regular files, each file
/// at most 4 MiB and the pack at most 32 MiB. The host sends each file as text;
/// the page validates (src/diff-languages/pack.ts).
nonisolated enum DiffLanguagePack {
    static let fileLimit = 4 * 1024 * 1024
    static let packLimit = 32 * 1024 * 1024

    static func directory(configFile: URL) -> URL {
        configFile.deletingLastPathComponent().appending(path: "diff/languages", directoryHint: .isDirectory)
    }

    /// `{files: [{path, text}]}`, empty when the folder does not exist.
    /// Blocking file IO: call it off the main actor.
    static func read(_ directory: URL) -> JSONValue {
        var files: [JSONValue] = []
        var total = 0
        func visit(_ relative: String, depth: Int) {
            let folder = relative.isEmpty ? directory : directory.appending(path: relative)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
            for name in names.sorted(by: { $0.localizedCompare($1) == .orderedAscending }) where !name.hasPrefix(".") {
                let child = relative.isEmpty ? name : relative + "/" + name
                guard let values = try? directory.appending(path: child).resolvingSymlinksInPath()
                    .resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else { continue }
                if values.isDirectory == true {
                    if depth == 0 { visit(child, depth: 1) }
                    continue
                }
                guard values.isRegularFile == true, name.hasSuffix(".json"), let size = values.fileSize,
                      size <= fileLimit, total + size <= packLimit,
                      // concurrency-allow: nonisolated reader; DiffLanguageFeed runs it from a @concurrent task
                      let text = try? String(contentsOf: directory.appending(path: child), encoding: .utf8) else { continue }
                files.append(["path": .string(child), "text": .string(text)])
                total += size
            }
        }
        visit("", depth: 0)
        return ["files": .array(files)]
    }

    /// What a watch should cover: the folder, its subfolders and its files, so
    /// an in-place save, an atomic rename and a new file all report.
    static func watchedURLs(_ directory: URL) -> [URL] {
        var urls = [directory]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if enumerator?.level ?? 0 >= 2 { enumerator?.skipDescendants() }
            urls.append(url)
            if urls.count >= 512 { break }
        }
        return urls
    }
}

/// The one language pack every diff tab gets: read when the first tab asks,
/// watched while any tab listens, pushed to every listener on a change (the
/// page's `cmux.diff.languages` stream). Main actor; every file system read
/// (the pack and the list of paths to watch) runs off it.
final class DiffLanguageFeed {
    private struct Snapshot: Sendable {
        let pack: JSONValue
        let watched: [URL]
    }

    private let directory: URL
    private var current: JSONValue?
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var watchers: [ConfigFileWatcher] = []
    private var reload: Task<Void, Never>?
    private var pending = false

    init(directory: URL) {
        self.directory = directory
    }

    /// The pack now (read once on first use).
    func pack() async -> JSONValue {
        if let current { return current }
        let snapshot = await Self.read(directory)
        if current == nil { current = snapshot.pack }
        return current ?? snapshot.pack
    }

    /// Calls `onChange` with every later pack until the returned cancel runs.
    func listen(_ onChange: @escaping @MainActor (JSONValue) -> Void) -> () -> Void {
        let id = UUID()
        let starting = listeners.isEmpty
        listeners[id] = onChange
        if starting { requestReload() }
        return { [weak self] in
            guard let self else { return }
            listeners[id] = nil
            if listeners.isEmpty { stopWatching() }
        }
    }

    var listenerCount: Int { listeners.count }
    /// Paths watched now (tests).
    var watcherCount: Int { watchers.count }

    /// Watches exactly `urls` (the folder, its subfolders and files), so a new
    /// file or folder gets its own watch after the read that found it.
    private func watch(_ urls: [URL]) {
        guard !listeners.isEmpty else { return }
        guard Set(urls.map(\.path)) != Set(watchers.map(\.url.path)) else { return }
        for watcher in watchers { watcher.stop() }
        watchers = urls.map { url in
            ConfigFileWatcher(url: url) { [weak self] in
                // task-owner: one hop to the main actor per file event
                Task { @MainActor in self?.requestReload() }
            }
        }
        for watcher in watchers { watcher.start() }
    }

    private func stopWatching() {
        for watcher in watchers { watcher.stop() }
        watchers = []
        reload?.cancel()
        reload = nil
        pending = false
    }

    private func requestReload() {
        guard !listeners.isEmpty else { return }
        pending = true
        guard reload == nil else { return }
        reload = Task { [weak self] in
            while let directory = self?.takePending() {
                let snapshot = await Self.read(directory)
                if Task.isCancelled { return }
                self?.apply(snapshot)
            }
            self?.reload = nil
        }
    }

    private func takePending() -> URL? {
        guard pending else { return nil }
        pending = false
        return directory
    }

    private func apply(_ snapshot: Snapshot) {
        watch(snapshot.watched)
        guard snapshot.pack != current else { return }
        let first = current == nil
        current = snapshot.pack
        // The first read only fills the cache; listeners started from it.
        guard !first else { return }
        for listener in listeners.values { listener(snapshot.pack) }
    }

    @concurrent private static func read(_ directory: URL) async -> Snapshot {
        Snapshot(pack: DiffLanguagePack.read(directory), watched: DiffLanguagePack.watchedURLs(directory))
    }
}
