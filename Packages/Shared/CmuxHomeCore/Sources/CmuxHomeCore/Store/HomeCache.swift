public import Foundation

/// The client's durable Home cache, one per owner and account
/// (`~/Library/Caches/cmux-home/<owner key>/` on the Mac): a Repository actor.
///
/// On disk it is a small index (`home.json`: the inbox, unsent sends, drafts, scroll anchors and
/// the list of cached windows) plus one file per opened conversation's window
/// (`home-windows/<conversation>.json`, its newest ``windowLimit`` messages). A write is
/// proportional to the change, not to the store: the actor keeps what it last wrote and rewrites
/// the index only when it changed and only the windows that changed (speed-of-sound-DESIGN.md
/// 3.5). Encoding and writing run on the actor, never on the caller's main actor, which hands
/// over a ``HomeCacheState`` of copy-on-write values. A file that does not decode is ignored,
/// since the owner can rebuild everything in it but drafts and unsent sends. An index written
/// whole by an older build (windows inline) still loads.
///
/// ```swift
/// let cache = HomeCache(url: temporaryDirectory.appendingPathComponent("home.json"))
/// try await cache.save(snapshot)
/// let restored = cache.load()
/// ```
public actor HomeCache {
    /// Messages kept per opened conversation.
    public static let windowLimit = 200

    /// Writes one file (data, then its URL): the default replaces it atomically (a temporary file renamed over
    /// it, so a process end mid-write never leaves a torn file) and makes it owner-only.
    public typealias FileWriter = @Sendable (Data, URL) throws -> Void

    /// The queue this actor runs on (threading-model.md, `com.cmuxterm.home.cache`): its file calls block a
    /// thread of its own, never a cooperative pool thread, so a full pool (a stuck quit) cannot hold the
    /// forced quit's last draft write.
    private nonisolated let queue = DispatchSerialQueue(label: "com.cmuxterm.home.cache", qos: .userInitiated)

    /// Runs the actor on ``queue``.
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private nonisolated let writeFile: FileWriter

    /// The index file; the windows are in ``windowsDirectory`` beside it.
    public nonisolated let url: URL

    /// What the files on disk hold, as last written or read; nil until the first write reads it.
    private var written: Written?
    /// The newest state written by each writer (a ``HomeClientViewCache`` numbers its states):
    /// an older one that reaches the actor later is dropped, since the newer one holds everything
    /// it does. Per writer: two stores on one cache number their states apart.
    private var lastSequence: [UUID: UInt64] = [:]

    private struct Written {
        /// The index as a value, not as bytes: `JSONEncoder` writes a struct's keys and a
        /// non-`String`-keyed dictionary's entries in hash order, so two encodes of one state can
        /// differ byte for byte. Comparing bytes rewrote `home.json` for an equal state.
        var index: HomeCacheSnapshot?
        /// Each window file's messages (the kept tail), compared with a new state's tail.
        var windows: [ConversationID: [Message]] = [:]
    }

    /// - Parameters:
    ///   - url: The index file (`home.json`).
    ///   - writeFile: Writes each file; the default replaces it atomically and makes it owner-only. Tests pass
    ///     one that fails or records.
    public init(url: URL, writeFile: @escaping FileWriter = { try HomeCache.atomicWrite($0, to: $1) }) {
        self.url = url
        self.writeFile = writeFile
    }

    /// `Caches/cmux-home/<owner>/home.json` in the user's Caches folder; `owner` is made a single path component.
    public static func standard(owner: String) -> HomeCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return standard(owner: owner, caches: caches)
    }

    /// `<caches>/cmux-home/<owner>/home.json`; `owner` is made a single path component.
    ///
    /// - Parameters:
    ///   - owner: The Chief owner the cache belongs to.
    ///   - caches: The folder that holds the Home caches: the user's Caches folder in the app, a
    ///     test's own temporary folder in a test, so no test reads another's drafts.
    /// - Returns: The cache at that path.
    public static func standard(owner: String, caches: URL) -> HomeCache {
        let component = String(owner.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        return HomeCache(url: caches.appendingPathComponent("cmux-home/\(component)/home.json"))
    }

    /// `home-windows/` beside `home.json`: one file per cached window.
    public nonisolated var windowsDirectory: URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-windows", isDirectory: true)
    }

    /// The cached snapshot, read synchronously (the Home list's first frame needs it before the
    /// owner answers). Nil when there is none or it does not decode; a window whose file is
    /// gone or does not decode is left out.
    public nonisolated func load() -> HomeCacheSnapshot? {
        guard var snapshot = readIndex() else { return nil }
        for id in snapshot.windowIDs ?? [] where snapshot.windows[id] == nil {
            if let messages = readWindow(id) { snapshot.windows[id] = messages }
        }
        snapshot.windowIDs = nil
        return snapshot
    }

    /// Writes `snapshot` as the newest state (tests, tools): the index and each window that
    /// differs from what is on disk.
    ///
    /// - Throws: `CocoaError(.fileWriteUnknown)` when a file did not reach disk.
    public func save(_ snapshot: HomeCacheSnapshot) throws {
        if !commit(HomeCacheState(snapshot)) { throw CocoaError(.fileWriteUnknown) }
    }

    /// Writes `state` unless `writer` already wrote a newer one; true when everything it holds is
    /// on disk (or a newer state replaced it).
    func write(_ state: HomeCacheState, sequence: UInt64, writer: UUID) -> Bool {
        guard sequence > lastSequence[writer, default: 0] else { return true }
        lastSequence[writer] = sequence
        return commit(state)
    }

    // MARK: - Files

    /// Writes the changed windows, then the index (so it never names a window not yet on disk),
    /// then removes the windows that left. True when all of it reached disk.
    ///
    /// The file calls block this actor's own queue (``unownedExecutor``), never a cooperative pool thread.
    private func commit(_ state: HomeCacheState) -> Bool {
        var written = self.written ?? readWritten()
        defer { self.written = written }
        do {
            try FileManager.default.createDirectory(at: windowsDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        var complete = true
        for (id, messages) in state.windows {
            let kept = Array(messages.suffix(Self.windowLimit))
            if written.windows[id] == kept { continue }
            if (try? writeFile(Self.encoder().encode(kept), windowURL(id))) != nil {
                written.windows[id] = kept
            } else {
                written.windows[id] = nil
                complete = false
            }
        }
        let index = state.index
        if index != written.index {
            if let data = try? Self.encoder().encode(index), (try? writeFile(data, url)) != nil {
                written.index = index
            } else {
                complete = false
            }
        }
        for id in written.windows.keys where state.windows[id] == nil {
            try? FileManager.default.removeItem(at: windowURL(id))
            written.windows[id] = nil
        }
        return complete
    }

    /// What is on disk before this launch's first write: the index and its windows. A
    /// window file the index does not name (left by an older build) is removed.
    private func readWritten() -> Written {
        var written = Written()
        let index = readIndex()
        written.index = index
        let named = Set(index?.windowIDs ?? [])
        for id in named {
            if let messages = readWindow(id) { written.windows[id] = messages }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: windowsDirectory, includingPropertiesForKeys: nil)) ?? []
        let namedFiles = Set(named.map { windowURL($0).lastPathComponent })
        for file in files where !namedFiles.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        return written
    }

    private nonisolated func readIndex() -> HomeCacheSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(HomeCacheSnapshot.self, from: data),
              snapshot.version == HomeCacheSnapshot.currentVersion else { return nil }
        return snapshot
    }

    /// Sorted keys order struct fields and String-keyed dictionaries only. ConversationID is not
    /// `CodingKeyRepresentable`, so the ConversationID-keyed dictionaries (drafts, scroll,
    /// draftAttachments) encode as unkeyed `[key, value, ...]` arrays in hash order:
    /// equal values can give different bytes, and the change test must stay a value compare.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private nonisolated func readWindow(_ id: ConversationID) -> [Message]? {
        guard let data = try? Data(contentsOf: windowURL(id)) else { return nil }
        return try? JSONDecoder().decode([Message].self, from: data)
    }

    /// The window's file: the id percent-encoded, so each id has its own name.
    private nonisolated func windowURL(_ id: ConversationID) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let name = id.rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? id.rawValue
        return windowsDirectory.appendingPathComponent(name + ".json")
    }

    /// The default ``FileWriter``: an atomic replace, then owner-only permissions.
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

