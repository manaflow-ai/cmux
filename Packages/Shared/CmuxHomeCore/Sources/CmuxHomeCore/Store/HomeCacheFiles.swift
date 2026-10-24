import Foundation

/// The files of one ``HomeCache`` and what they hold: the commit every write runs, the
/// proportional rewrite (only the index when it changed, only the windows that changed) and the
/// newest state number per writer.
///
/// Its mutable state is touched only on the cache actor's executor queue: by the actor's own
/// methods (which run there) and by ``HomeCache/writeBlocking(_:sequence:writer:)`` (which runs
/// there with `queue.sync`). The reads used by `load()` touch no mutable state.
// Mutable state only on HomeCache's executor queue (see above); never touched elsewhere.
final class HomeCacheFiles: @unchecked Sendable {
    /// The index file; the windows are in ``windowsDirectory`` beside it.
    let url: URL

    /// What the files on disk hold, as last written or read; nil until the first write reads it.
    private var written: Written?
    /// The newest state written by each writer (a ``HomeClientViewCache`` numbers its states):
    /// an older one that comes later is dropped, since the newer one holds everything it does.
    /// Per writer: two stores on one cache number their states apart.
    private var lastSequence: [UUID: UInt64] = [:]

    private struct Written {
        /// The index as a value: an equal state is found without encoding anything (the index's
        /// bytes are a function of its value too, ``HomeCacheSnapshot/encode(to:)``).
        var index: HomeCacheSnapshot?
        /// Each window file's messages (the kept tail), compared with a new state's tail.
        var windows: [ConversationID: [Message]] = [:]
    }

    init(url: URL) {
        self.url = url
    }

    /// `home-windows/` beside `home.json`: one file per cached window.
    var windowsDirectory: URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-windows", isDirectory: true)
    }

    /// Writes `state` unless `writer` already wrote a newer one; true when everything it holds is
    /// on disk (or a newer state replaced it). On the cache's executor queue.
    func write(_ state: HomeCacheState, sequence: UInt64, writer: UUID) -> Bool {
        guard sequence > lastSequence[writer, default: 0] else { return true }
        lastSequence[writer] = sequence
        return commit(state)
    }

    /// Writes the changed windows, then the index (so it never names a window not yet on disk),
    /// then removes the windows that left. True when all of it reached disk. On the cache's
    /// executor queue.
    func commit(_ state: HomeCacheState) -> Bool {
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
            let kept = Array(messages.suffix(HomeCache.windowLimit))
            if written.windows[id] == kept { continue }
            if (try? Self.writeFile(Self.encoder().encode(kept), to: windowURL(id))) != nil {
                written.windows[id] = kept
            } else {
                written.windows[id] = nil
                complete = false
            }
        }
        let index = state.index
        if index != written.index {
            if let data = try? Self.encoder().encode(index), (try? Self.writeFile(data, to: url)) != nil {
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

    /// The index on disk; nil when there is none, it does not decode or is another version.
    /// Touches no mutable state (any thread).
    func readIndex() -> HomeCacheSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(HomeCacheSnapshot.self, from: data),
              snapshot.version == HomeCacheSnapshot.currentVersion else { return nil }
        return snapshot
    }

    /// A window's messages on disk; nil when its file is gone or does not decode. Touches no
    /// mutable state (any thread).
    func readWindow(_ id: ConversationID) -> [Message]? {
        guard let data = try? Data(contentsOf: windowURL(id)) else { return nil }
        return try? JSONDecoder().decode([Message].self, from: data)
    }

    /// Sorted keys: with ``HomeCacheSnapshot/encode(to:)``, which writes the conversation-keyed
    /// dictionaries in key order, equal values give equal bytes.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// The window's file: the id percent-encoded, so each id has its own name.
    private func windowURL(_ id: ConversationID) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let name = id.rawValue.addingPercentEncoding(withAllowedCharacters: allowed) ?? id.rawValue
        return windowsDirectory.appendingPathComponent(name + ".json")
    }

    private static func writeFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
