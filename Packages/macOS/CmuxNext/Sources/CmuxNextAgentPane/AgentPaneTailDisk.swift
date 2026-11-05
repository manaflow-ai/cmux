import CmuxNextCompat
public import CmuxNextSettings
import CryptoKit
public import Foundation

/// The disk tier under ``AgentPaneTailCache``: each chat's kept tail as one small JSON file, so a
/// chat opened from the sidebar or a link draws its last read rows before acpmux's attach answers,
/// also right after the app restarted, when the memory tier is empty (Leo, 2026-11-05: "there's
/// stuff opening up subagents or opening up other sessions. Those need to be fast. There's no
/// reason for them to have a delay, even under load.").
///
/// Every disk touch runs on one serial utility queue, never on the main thread: a save is handed
/// a value and encodes on the queue, a read is awaited holding no thread. Saves of one chat
/// coalesce (a save a newer one replaced before it ran is skipped), and reads queue behind the
/// saves made before them, so a read sees the newest tail handed over.
///
/// Bounded as the memory tier is: at most ``AgentPaneTailCache/chats`` files (the least recently
/// written go first) of at most ``AgentPaneTailCache/bytes`` each, so about 20 MiB in the worst
/// case. A file over the bound, or one that does not decode as a tail, is removed and read as none.
/// File names are a hash of the session id, so no id names a path. ``clear()`` (sign-out) removes
/// the whole folder.
public nonisolated final class AgentPaneTailDisk: Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.agent-pane.tail-disk", qos: .utility)
    /// The newest save's number per file name: a queued save with an older one does nothing.
    private let newest = Mutex<[String: UInt64]>([:])
    private let counter = Mutex<UInt64>(0)
    private let limitFiles: Int
    private let limitBytes: Int
    /// Told each time a ``read(_:)`` is queued, before it runs (a test holds the queue there).
    private let readQueued: @Sendable () -> Void

    public init(directory: URL, files: Int = AgentPaneTailCache.chats, bytes: Int = AgentPaneTailCache.bytes,
                readQueued: @escaping @Sendable () -> Void = {}) {
        self.directory = directory
        limitFiles = files
        limitBytes = bytes
        self.readQueued = readQueued
    }

    /// The file chat `sessionId`'s tail is kept in.
    func url(for sessionId: String) -> URL {
        let digest = SHA256.hash(data: Data(sessionId.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).json")
    }

    /// Saves `tail` for `sessionId` off the main thread; nil removes its file.
    public func write(_ tail: JSONValue?, for sessionId: String) {
        let file = url(for: sessionId)
        let name = file.lastPathComponent
        let number = counter.withLock { $0 += 1; return $0 }
        newest.withLock { $0[name] = number }
        queue.async { [self] in
            guard newest.withLock({ $0[name] == number }) else { return }
            newest.withLock { if $0[name] == number { $0[name] = nil } }
            guard let tail else {
                try? FileManager.checked.removeItem(at: file)
                return
            }
            var text = ""
            tail.appendCompactText(to: &text)
            let data = Data(text.utf8)
            guard data.count <= limitBytes else {
                try? FileManager.checked.removeItem(at: file)
                return
            }
            try? FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.blockingWrite(to: file, options: .atomic)
            trim()
        }
    }

    /// The tail kept for `sessionId` once the saves queued before this call have run; nil when
    /// there is none, or the file is over the bound or is no tail.
    public func read(_ sessionId: String) async -> JSONValue? {
        let file = url(for: sessionId)
        let limit = limitBytes
        return await withCheckedContinuation { (done: CheckedContinuation<JSONValue?, Never>) in
            queue.async {
                done.resume(returning: Self.load(file, limit: limit))
            }
            readQueued()
        }
    }

    /// Removes every kept tail, after the saves queued before this call.
    public func clear() {
        newest.withLock { $0.removeAll() }
        queue.async { [directory] in try? FileManager.checked.removeItem(at: directory) }
    }

    /// Returns, holding no thread, once the work queued before this call has run.
    public func settled() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    /// Runs `work` on the queue after the work queued before it (a test holds the queue with it).
    func afterQueued(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    private static func load(_ file: URL, limit: Int) -> JSONValue? {
        let size = (try? file.blockingResourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let size else { return nil }
        guard size <= limit, let data = try? Data(blockingContentsOf: file),
              let tail = try? JSONDecoder().decode(JSONValue.self, from: data), AgentPaneTailCache.holds(tail)
        else {
            try? FileManager.checked.removeItem(at: file)
            return nil
        }
        return tail
    }

    /// Keeps the newest ``limitFiles`` files, by modification date. On the queue only.
    private func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.checked.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > limitFiles else { return }
        let dated = files.map { ($0, (try? $0.blockingResourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(limitFiles) {
            try? FileManager.checked.removeItem(at: file)
        }
    }
}
