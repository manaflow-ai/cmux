public import CmuxNextSettings
public import Foundation
public import CmuxNextWakeups

/// The user's diff viewer language pack, read the way the page dev host reads
/// it (webviews/dev-server/diffLanguages.ts): every `*.json` file directly in
/// `<dir of cmux.json>/diff/languages` and one level of subfolders, by name,
/// hidden entries skipped, symlinks followed only to regular files, each file
/// at most 4 MiB and the pack at most 32 MiB. The host sends each file as text;
/// the page validates (src/diff-languages/pack.ts).
public nonisolated enum DiffLanguagePack {
    static let fileLimit = 4 * 1024 * 1024
    static let packLimit = 32 * 1024 * 1024

    public static func directory(configFile: URL) -> URL {
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
public final class DiffLanguageFeed {
    private struct Snapshot: Sendable {
        let pack: JSONValue
        let watched: [URL]
    }

    private let directory: URL
    private var current: JSONValue?
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var watchers: [ConfigFileWatcher] = []
    /// The read in flight; a change during it reads again when it lands.
    private var reload: Task<Void, Never>?
    /// Which read is current: a read `stopWatching()` dropped lands on an older id and does nothing.
    private var reloadID: UInt64 = 0
    private var pending = false
    /// Where the file notices and the reads' packs reach the main thread.
    private let mainWork: MainWorkScheduler

    /// - Parameters:
    ///   - directory: The language pack's folder.
    ///   - mainWork: The app's one main-thread scheduler: each file notice and each read pack is one task on it.
    public init(directory: URL, mainWork: MainWorkScheduler) {
        self.directory = directory
        self.mainWork = mainWork
    }

    /// The pack now (read once on first use).
    func pack() async -> JSONValue {
        if let current { return current }
        let snapshot = await Self.read(directory)
        if current == nil { current = snapshot.pack }
        return current ?? snapshot.pack
    }

    /// Calls `onChange` with every later pack until the returned cancel runs.
    public func listen(_ onChange: @escaping @MainActor (JSONValue) -> Void) -> () -> Void {
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
        let mainWork = mainWork
        watchers = urls.map { url in
            // Each notice arrives on the watcher's queue and posts one background task: the reload reads off main.
            ConfigFileWatcher(url: url) { [weak self] in
                mainWork.postFromAnyThread(.background, owner: "DiffLanguageFeed.fileChanged") { [weak self] in self?.requestReload() }
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
        readPending()
    }

    /// Reads the pack off main if a change is pending; its pack lands as one `visible` task (open diff tabs show
    /// it), which reads again for a change that came meanwhile.
    private func readPending() {
        guard let directory = takePending() else {
            reload = nil
            return
        }
        reloadID &+= 1
        let id = reloadID, mainWork = mainWork
        reload = Task { @concurrent [weak self] in
            let snapshot = await Self.read(directory)
            guard !Task.isCancelled else { return }
            await mainWork.apply(.visible, owner: "DiffLanguageFeed.reload") { [weak self] () -> Void in
                self?.reloaded(snapshot, id: id)
            }
        }
    }

    private func reloaded(_ snapshot: Snapshot, id: UInt64) {
        guard reload != nil, id == reloadID else { return }
        apply(snapshot)
        readPending()
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
