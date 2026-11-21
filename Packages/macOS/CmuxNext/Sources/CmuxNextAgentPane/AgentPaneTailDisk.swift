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
/// Bounded by bytes, not by a count of chats: files of at most ``AgentPaneTailCache/bytes`` each,
/// at most ``files`` of them, adding up to at most ``totalBytes`` (20 MiB, the old worst case of
/// twenty full files). A trim walks them newest first and keeps each that still fits: one that
/// would go over is removed, and an older, smaller one that fits after it stays. Twenty files
/// kept the twenty chats written last, and a big chat that streams writes every few seconds, so a
/// quiet small chat fell out and opened cold after a restart while the big one drew at once (Leo,
/// 2026-11-13: "why cant small ones be faster too?"). By bytes, a small chat costs what it holds.
/// A file over the bound, or one that does not decode as a tail, is removed and read as none.
/// File names are a hash of the session id, so no id names a path. ``clear()`` (sign-out) removes
/// the whole folder. The app has one per folder, from ``AgentPaneStateFiles/tails(in:)``, so the
/// quit awaits its queued saves with the other state files' (#36492 review F3).
public nonisolated final class AgentPaneTailDisk: Sendable {
    public let directory: URL
    private let queue: DispatchQueue
    /// The newest save's number per file name: a queued save with an older one does nothing.
    private let newest = Mutex<[String: UInt64]>([:])
    private let counter = Mutex<UInt64>(0)
    /// Saves queued and not yet run (or skipped), for ``isSaving``.
    private let pending = Mutex<Int>(0)
    private let limitFiles: Int
    private let limitBytes: Int
    private let limitTotal: Int
    /// Most files one folder keeps, so a trim's listing stays small whatever the chats weigh.
    public static let files = 500
    /// Most bytes one folder's files add up to: twenty full files, the bound when it was by count.
    public static let totalBytes = 20 * AgentPaneTailCache.bytes
    /// Whether a file read back is one this keeps (a tail, by default); one that is not is removed.
    private let accepts: @Sendable (JSONValue) -> Bool
    /// Told each time a ``read(_:)`` is queued, before it runs (a test holds the queue there).
    private let readQueued: @Sendable () -> Void

    /// - Parameters:
    ///   - accepts: Whether a value read back is one this keeps: a chat tail when nil; the chats'
    ///     drawn copies (``AgentPaneChatSnapshots``) keep theirs in a disk of their own.
    ///   - qos: The queue's class: utility for tails, user-initiated for a copy the next document
    ///     waits on before its first frame.
    public init(directory: URL, files: Int = AgentPaneTailDisk.files, bytes: Int = AgentPaneTailCache.bytes,
                totalBytes: Int = AgentPaneTailDisk.totalBytes,
                qos: DispatchQoS = .utility,
                accepts: (@Sendable (JSONValue) -> Bool)? = nil,
                readQueued: @escaping @Sendable () -> Void = {}) {
        self.directory = directory
        limitFiles = files
        limitBytes = bytes
        limitTotal = totalBytes
        self.accepts = accepts ?? { AgentPaneTailCache.holds($0) }
        self.readQueued = readQueued
        queue = DispatchQueue(label: "com.cmuxterm.app.next.agent-pane.tail-disk", qos: qos)
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
        pending.withLock { $0 += 1 }
        queue.async { [self] in
            defer { pending.withLock { $0 -= 1 } }
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
        let accepts = accepts
        return await withCheckedContinuation { (done: CheckedContinuation<JSONValue?, Never>) in
            queue.async {
                done.resume(returning: Self.load(file, limit: limit, accepts: accepts))
            }
            readQueued()
        }
    }

    /// Removes every kept tail, after the saves queued before this call.
    public func clear() {
        newest.withLock { $0.removeAll() }
        queue.async { [directory] in try? FileManager.checked.removeItem(at: directory) }
    }

    /// Whether a save is queued and has not run yet (the quit deadline's record names the folder).
    public var isSaving: Bool { pending.withLock { $0 > 0 } }

    /// Returns, holding no thread, once the work queued before this call has run.
    public func settled() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
    }

    /// Runs `work` on the queue after the work queued before it (a test holds the queue with it).
    func afterQueued(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    private static func load(_ file: URL, limit: Int, accepts: (JSONValue) -> Bool) -> JSONValue? {
        let size = (try? file.blockingResourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let size else { return nil }
        guard size <= limit, let data = try? Data(blockingContentsOf: file),
              let tail = try? JSONDecoder().decode(JSONValue.self, from: data), accepts(tail)
        else {
            try? FileManager.checked.removeItem(at: file)
            return nil
        }
        return tail
    }

    /// Walks the files newest first, by modification date, and keeps each while fewer than
    /// ``limitFiles`` are kept and it still fits in ``limitTotal``; one that does not fit is removed
    /// and the walk goes on, so an older, smaller file can stay. The newest is always kept. On the
    /// queue only.
    private func trim() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.checked.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        else { return }
        let dated = files.map { file in
            let values = try? file.blockingResourceValues(forKeys: keys)
            return (file, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }
        var kept = 0
        var total = 0
        for (file, _, size) in dated.sorted(by: { $0.1 > $1.1 }) {
            if kept == 0 || (kept < limitFiles && total + size <= limitTotal) {
                kept += 1
                total += size
            } else {
                try? FileManager.checked.removeItem(at: file)
            }
        }
    }
}
