import CmuxCommandPalette
import Foundation

/// Lazily indexes directories under a home folder for the mobile Dispatch picker.
actor DispatchDirectoryIndex {
    struct Entry: Sendable, Equatable {
        let path: String
        let name: String
        let git: Bool
        let depth: Int
    }

    struct SearchResult: Sendable {
        let entries: [Entry]
        let indexing: Bool
        let truncated: Bool
    }

    struct DirectoryListing: Sendable {
        let path: String
        let entries: [Entry]
        let truncated: Bool
        let notice: Notice?
    }

    struct Notice: Sendable {
        let code: String
        let message: String
    }

    enum ListingError: Error, Sendable {
        case notFound(path: String)
        case unavailable(path: String, message: String)
    }

    private struct ScanNode: Sendable {
        let path: String
        let depth: Int
    }

    private struct ScanResult: Sendable {
        let truncated: Bool
    }

    nonisolated let homeDirectoryPath: String

    private static let maximumDepth = 8
    private static let maximumDirectoryCount = 60_000
    private static let listingLimit = 400
    private static let refreshInterval: TimeInterval = 10 * 60
    private static let publishBatchSize = 64

    /// Prepared once per directory at publish time: corpus-entry preparation
    /// (normalization, prefix score maps) is far too expensive to redo per
    /// query over tens of thousands of directories.
    private var corpus: [CommandPaletteSearchCorpusEntry<Entry>] = []
    private var buildingCorpus: [CommandPaletteSearchCorpusEntry<Entry>] = []
    /// Rust nucleo index over the completed corpus. The pure-Swift fuzzy
    /// engine's stitched-prefix scoring is quadratic-ish over path words and
    /// takes seconds at home-directory scale (verified by sampling); nucleo
    /// answers the same corpus in milliseconds. Built once per completed scan.
    private var nucleoIndex: CommandPaletteNucleoSearchIndex<Entry>?
    private var builtAt: Date?
    private var indexWasTruncated = false
    private var buildTask: Task<Void, Never>?
    private var buildGeneration = 0

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        homeDirectoryPath = homeDirectory.standardizedFileURL.path
    }

    func list(path rawPath: String, includeHidden: Bool) -> Result<DirectoryListing, ListingError> {
        let path = resolvedPath(rawPath)
        let fileManager = FileManager()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.notFound(path: path))
        }

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: path, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            var entries: [Entry] = []
            entries.reserveCapacity(min(urls.count, Self.listingLimit + 1))
            for url in urls {
                if !includeHidden, url.lastPathComponent.hasPrefix(".") { continue }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                entries.append(Self.entry(url: url, depth: 1, fileManager: fileManager))
            }
            entries.sort { lhs, rhs in
                let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.path < rhs.path
            }
            let truncated = entries.count > Self.listingLimit
            return .success(DirectoryListing(
                path: path,
                entries: Array(entries.prefix(Self.listingLimit)),
                truncated: truncated,
                notice: nil
            ))
        } catch {
            if Self.isPermissionDenied(error) {
                return .success(DirectoryListing(
                    path: path,
                    entries: [],
                    truncated: false,
                    notice: Notice(code: "permission_denied", message: error.localizedDescription)
                ))
            }
            return .failure(.unavailable(path: path, message: error.localizedDescription))
        }
    }

    func search(query: String, limit requestedLimit: Int = 50, now: Date = Date()) -> SearchResult {
        let needsRefresh = builtAt.map { now.timeIntervalSince($0) >= Self.refreshInterval } ?? true
        if needsRefresh, buildTask == nil {
            startBuild()
        }

        let limit = min(max(requestedLimit, 1), 100)
        let matchedEntries: [Entry]
        if let nucleoIndex,
           let nucleoRanked = nucleoIndex.search(
               query: query,
               resultLimit: limit + 1,
               historyBoost: { entry, _ in entry.git ? 350 : 0 }
           ) {
            matchedEntries = nucleoRanked.map(\.payload)
        } else {
            matchedEntries = Self.fallbackRanked(
                corpus: corpus.isEmpty ? buildingCorpus : corpus,
                query: query,
                limit: limit + 1
            )
        }
        return SearchResult(
            entries: Array(matchedEntries.prefix(limit)),
            indexing: buildTask != nil,
            truncated: indexWasTruncated || matchedEntries.count > limit
        )
    }

    /// Mid-build (or nucleo-unavailable) ranking: a cheap case-insensitive
    /// substring prefilter bounds the candidate set before the expensive Swift
    /// fuzzy engine runs, so searches stay responsive while results fill in.
    private nonisolated static func fallbackRanked(
        corpus: [CommandPaletteSearchCorpusEntry<Entry>],
        query: String,
        limit: Int
    ) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var survivors: [CommandPaletteSearchCorpusEntry<Entry>] = []
        let survivorCap = 1500
        for entry in corpus {
            if entry.nucleoSearchText.range(of: needle, options: .caseInsensitive) != nil {
                survivors.append(entry)
                if survivors.count >= survivorCap { break }
            }
        }
        guard !survivors.isEmpty else { return [] }
        return CommandPaletteSearchEngine(entries: survivors).search(
            query: needle,
            resultLimit: limit,
            historyBoost: { entry, _ in entry.git ? 350 : 0 }
        ).map(\.payload)
    }

    /// Completes the current build, or starts one when the index is idle.
    func rebuild() async {
        if buildTask == nil {
            startBuild()
        }
        await buildTask?.value
    }

    private func startBuild() {
        buildGeneration += 1
        let generation = buildGeneration
        buildingCorpus = []
        let homePath = homeDirectoryPath
        buildTask = Task.detached(priority: .utility) { [self] in
            let result = await Self.scan(
                homePath: homePath,
                generation: generation,
                index: self
            )
            await finishBuild(generation: generation, result: result)
        }
    }

    private func publish(_ prepared: [CommandPaletteSearchCorpusEntry<Entry>], generation: Int) {
        guard generation == buildGeneration else { return }
        buildingCorpus.append(contentsOf: prepared)
    }

    private func finishBuild(generation: Int, result: ScanResult) {
        guard generation == buildGeneration else { return }
        corpus = buildingCorpus
        buildingCorpus = []
        nucleoIndex = corpus.count >= 32 ? CommandPaletteNucleoSearchIndex(entries: corpus) : nil
        builtAt = Date()
        indexWasTruncated = result.truncated
        buildTask = nil
    }

    /// Corpus-entry preparation happens on the detached scan task, off both the
    /// main actor and this actor, so neither RPC handling nor searches stall
    /// behind text normalization.
    private nonisolated static func preparedCorpusEntry(
        _ entry: Entry,
        homePath: String
    ) -> CommandPaletteSearchCorpusEntry<Entry> {
        // The name is not repeated in searchableTexts: the prepared title
        // already scores it (with a bonus), and corpus-entry preparation is
        // the scan's dominant cost at home-directory scale.
        CommandPaletteSearchCorpusEntry(
            payload: entry,
            rank: entry.depth,
            title: entry.name,
            searchableTexts: [relativePath(entry.path, homePath: homePath)]
        )
    }

    private func resolvedPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String
        if trimmed == "~" {
            expanded = homeDirectoryPath
        } else if trimmed.hasPrefix("~/") {
            expanded = homeDirectoryPath + String(trimmed.dropFirst())
        } else {
            expanded = trimmed
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.path
    }

    private nonisolated static func scan(
        homePath: String,
        generation: Int,
        index: DispatchDirectoryIndex
    ) async -> ScanResult {
        let home = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL.path
        // Breadth-first, so every top-level tree is represented before the
        // directory cap can bite. A depth-first walk exhausted the whole cap
        // inside the first few huge sibling trees and left entire top-level
        // folders (and their projects) unsearchable.
        var queue = [ScanNode(path: home, depth: 0)]
        var queueHead = 0
        var batch: [CommandPaletteSearchCorpusEntry<Entry>] = []
        batch.reserveCapacity(publishBatchSize)
        var directoryCount = 0
        var truncated = false

        while queueHead < queue.count {
            let node = queue[queueHead]
            queueHead += 1
            if Task.isCancelled { break }
            guard node.depth < maximumDepth else { continue }
            // readdir with d_type instead of FileManager URL enumeration: the
            // resource-key variant open()s every child (files included), which
            // took tens of minutes on a large real home directory (sampled).
            // d_type identifies subdirectories with zero per-child syscalls.
            for name in childDirectoryNames(of: node.path).sorted() {
                let childPath = node.path + "/" + name
                let components = relativeComponents(childPath, homePath: home)
                if shouldSkip(components) {
                    continue
                }

                directoryCount += 1
                if directoryCount > maximumDirectoryCount {
                    truncated = true
                    break
                }
                let depth = node.depth + 1
                batch.append(preparedCorpusEntry(
                    Entry(
                        path: childPath,
                        name: name,
                        git: access(childPath + "/.git", F_OK) == 0,
                        depth: depth
                    ),
                    homePath: home
                ))
                if depth < maximumDepth {
                    queue.append(ScanNode(path: childPath, depth: depth))
                }
                if batch.count >= publishBatchSize {
                    await index.publish(batch, generation: generation)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if truncated { break }
        }

        if !batch.isEmpty {
            await index.publish(batch, generation: generation)
        }
        return ScanResult(truncated: truncated)
    }

    /// Single-level entry construction for browse listings (which keep the
    /// FileManager URL path: one level at a time is cheap).
    private nonisolated static func entry(url: URL, depth: Int, fileManager: FileManager) -> Entry {
        Entry(
            path: url.standardizedFileURL.path,
            name: url.lastPathComponent,
            git: fileManager.fileExists(atPath: url.appendingPathComponent(".git").path),
            depth: depth
        )
    }

    /// Names of `node`'s immediate subdirectories via `readdir`'s `d_type`,
    /// so classifying children costs no stat/open per entry. `DT_UNKNOWN`
    /// (some filesystems) falls back to one `lstat`; symlinks are excluded.
    private nonisolated static func childDirectoryNames(of path: String) -> [String] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let rawEntry = readdir(dir) {
            let type = rawEntry.pointee.d_type
            guard type == DT_DIR || type == DT_UNKNOWN else { continue }
            let name = withUnsafeBytes(of: rawEntry.pointee.d_name) { rawBuffer -> String? in
                guard let base = rawBuffer.baseAddress else { return nil }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            guard let name, name != ".", name != ".." else { continue }
            if type == DT_UNKNOWN {
                var status = stat()
                guard lstat(path + "/" + name, &status) == 0,
                      (status.st_mode & S_IFMT) == S_IFDIR else { continue }
            }
            names.append(name)
        }
        return names
    }

    private nonisolated static func relativePath(_ path: String, homePath: String) -> String {
        relativeComponents(path, homePath: homePath).joined(separator: "/")
    }

    private nonisolated static func relativeComponents(_ path: String, homePath: String) -> [String] {
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        let homeComponents = URL(fileURLWithPath: homePath).standardizedFileURL.pathComponents
        guard pathComponents.starts(with: homeComponents) else { return pathComponents }
        return Array(pathComponents.dropFirst(homeComponents.count))
    }

    private nonisolated static func shouldSkip(_ components: [String]) -> Bool {
        guard let name = components.last else { return false }
        if [".git", "node_modules", ".Trash", ".cache", ".npm", ".gradle", "DerivedData"].contains(name) {
            return true
        }
        // TCC-protected roots: enumerating them from a background scan pops a
        // surprise macOS privacy dialog, and a raw readdir() BLOCKS inside the
        // syscall until the user answers it, freezing the whole walk (hit
        // live: the scan froze at ~/Movies). Browse-into still reaches them,
        // prompting at a user-intentional moment instead.
        if components.count == 1, ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].contains(name) {
            return true
        }
        // Top-level dot-trees (~/.claude, ~/.npm, …) are tool state, not
        // projects; they flood search with noise. Browse still reaches them.
        if components.count == 1, name.hasPrefix(".") {
            return true
        }
        if components == ["Library"] { return true }
        if components.count >= 2,
           components[components.count - 2] == ".cargo",
           name == "registry" {
            return true
        }
        return false
    }

    private nonisolated static func isPermissionDenied(_ error: Error) -> Bool {
        var currentError: NSError? = error as NSError
        while let current = currentError {
            if current.domain == NSCocoaErrorDomain, current.code == NSFileReadNoPermissionError {
                return true
            }
            currentError = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
