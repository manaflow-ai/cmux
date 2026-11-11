import Foundation
import os

/// The newest messages of a conversation as this device last saw them, so a store built again
/// (the app back from the background, a relaunch, a reconnect) shows them at once instead of a
/// spinner, the way Messages and WhatsApp keep a chat on the phone. The server's newest page
/// replaces them as soon as it arrives (`ConversationStore.applyNewest`).
public struct ConversationTranscriptSnapshot: Sendable, Hashable, Codable {
    public var info: ConversationInfo?
    public var meID: String?
    /// Acknowledged messages, oldest first, at most `ConversationTranscriptCache.limit`.
    public var messages: [ConversationMessage]

    public init(info: ConversationInfo?, meID: String?, messages: [ConversationMessage]) {
        self.info = info
        self.meID = meID
        self.messages = messages
    }
}

/// Keeps one `ConversationTranscriptSnapshot` per conversation key on disk (Application Support,
/// readable after first unlock) and the ones read or written this run in memory, so a store made
/// again in the same run shows them in the same frame. Disk reads and writes run in order on one
/// utility queue, never on the main thread. The files together stay under `byteLimit`: after each
/// write the least recently written conversations go first. Sign-out deletes them all (`removeAll`).
public final class ConversationTranscriptCache: @unchecked Sendable {
    /// Messages kept per conversation: the newest screens, not the history (older pages still
    /// come from the server when the reader scrolls up).
    public static let limit = 200
    /// Bytes kept on disk for every conversation together: the newest conversations stay, the
    /// ones written longest ago leave first (the user, 2026-11-09: "chats preserved on disk up to
    /// a storage limit, latest kept").
    public static let byteLimit = 32 * 1024 * 1024

    public let directory: URL
    public let limit: Int
    public let byteLimit: Int
    let queue = DispatchQueue(label: "dev.cmux.conversation.transcript-cache", qos: .utility)
    /// How long a write waits for newer changes (a streamed reply changes the transcript many
    /// times a second): one file write per key per `writeDelay`, of the newest snapshot.
    let writeDelay: DispatchTimeInterval
    /// Snapshots waiting for their write, by key; the queue takes the newest.
    private let pending = OSAllocatedUnfairLock(initialState: [String: ConversationTranscriptSnapshot]())
    /// This run's snapshots by key. Read and written on the main actor only.
    @MainActor private var memory: [String: ConversationTranscriptSnapshot] = [:]
    /// Bumps on `removeAll`: a read that started before it never lands in memory after it.
    @MainActor private var generation = 0

    public init(directory: URL, limit: Int = ConversationTranscriptCache.limit, byteLimit: Int = ConversationTranscriptCache.byteLimit,
                writeDelay: DispatchTimeInterval = .seconds(1)) {
        self.directory = directory
        self.limit = limit
        self.byteLimit = byteLimit
        self.writeDelay = writeDelay
    }

    /// The cache in Application Support/`name`.
    public static func inApplicationSupport(_ name: String) -> ConversationTranscriptCache {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ConversationTranscriptCache(directory: base.appending(path: name, directoryHint: .isDirectory))
    }

    /// The snapshot for `key` read or written this run, without touching the disk.
    @MainActor public func cached(_ key: String) -> ConversationTranscriptSnapshot? { memory[key] }

    /// The snapshot for `key`: from memory, else read from disk off the main thread.
    @MainActor public func load(_ key: String) async -> ConversationTranscriptSnapshot? {
        if let held = memory[key] { return held }
        let url = file(for: key), started = generation
        let read: ConversationTranscriptSnapshot? = await withCheckedContinuation { continuation in
            queue.async {
                let data = try? Data(contentsOf: url)
                continuation.resume(returning: data.flatMap { try? JSONDecoder().decode(ConversationTranscriptSnapshot.self, from: $0) })
            }
        }
        guard started == generation else { return nil }
        // A save during the read is newer than what was on disk.
        if let held = memory[key] { return held }
        if let read { memory[key] = read }
        return read
    }

    /// Keeps the newest `limit` acknowledged messages of `messages` for `key`: in memory now, on
    /// disk on the queue. Sends not yet acknowledged and their image bytes are not kept (the
    /// outbox owns unsent messages).
    @MainActor public func save(_ key: String, info: ConversationInfo?, meID: String?, messages: [ConversationMessage]) {
        let snapshot = Self.snapshot(info: info, meID: meID, messages: messages, limit: limit)
        guard memory[key] != snapshot else { return }
        memory[key] = snapshot
        let waiting = pending.withLock { pending in
            defer { pending[key] = snapshot }
            return pending[key] != nil
        }
        guard !waiting else { return }
        queue.asyncAfter(deadline: .now() + writeDelay) { [self] in write(key) }
    }

    /// Writes the newest snapshot waiting for `key`, if any (on the queue).
    private func write(_ key: String) {
        guard let snapshot = pending.withLock({ $0.removeValue(forKey: key) }),
              let data = try? JSONEncoder().encode(snapshot) else { return }
        var directory = directory
        if !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Kept messages are a copy of the server's: not in device backups.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        let written = file(for: key)
        guard (try? data.write(to: written, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else { return }
        Self.trim(directory, to: byteLimit, keeping: written)
    }

    /// Deletes the files of `directory` written longest ago until the rest fit in `byteLimit`
    /// bytes, never `keeping` (the file just written). Runs on the caller's queue (a cache's
    /// utility queue, never the main thread). Other on-disk caches with a total limit share it.
    public static func trim(_ directory: URL, to byteLimit: Int, keeping: URL?) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                       options: [.skipsHiddenFiles]) else { return }
        let kept = keeping?.standardizedFileURL.path(percentEncoded: false)
        var total = 0
        var candidates: [(url: URL, size: Int, date: Date)] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            total += size
            if url.standardizedFileURL.path(percentEncoded: false) != kept {
                candidates.append((url, size, values.contentModificationDate ?? .distantPast))
            }
        }
        guard total > byteLimit else { return }
        for candidate in candidates.sorted(by: { $0.date < $1.date }) {
            guard total > byteLimit else { break }
            if (try? FileManager.default.removeItem(at: candidate.url)) != nil { total -= candidate.size }
        }
    }

    /// Sign-out: every kept conversation leaves this device. Writes not yet made are dropped
    /// now; the files go on the queue, after any write already running.
    @MainActor public func removeAll() {
        memory = [:]
        generation += 1
        pending.withLock { $0 = [:] }
        let directory = directory
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Makes every waiting write now and returns once the queue is done (tests, never main-thread code).
    public func flush() {
        queue.sync {
            for key in pending.withLock({ Array($0.keys) }) { write(key) }
        }
    }

    nonisolated static func snapshot(info: ConversationInfo?, meID: String?, messages: [ConversationMessage], limit: Int) -> ConversationTranscriptSnapshot {
        // From the end: a long transcript (older pages loaded) is not walked whole.
        let kept = messages.lazy.filter { $0.seq != nil && !$0.isScheduled }.suffix(limit).map { message -> ConversationMessage in
            var message = message
            for index in message.attachments.indices { message.attachments[index].localData = nil }
            return message
        }
        return ConversationTranscriptSnapshot(info: info, meID: meID, messages: Array(kept))
    }

    private func file(for key: String) -> URL {
        directory.appending(path: "\(Self.fileName(for: key)).json")
    }

    /// The file name for `key`, one per key: ASCII letters, digits and `-` as they are, every other
    /// UTF-8 byte as `_` and two hex digits (`mac:m1` is `mac_3Am1`). Mapping each of them to `_`
    /// gave `mac:a.b`, `mac:a/b` and `mac_a_b` one file, so one conversation showed another's kept
    /// messages. An empty key is `_`, which no escape is; a name past 200 bytes keeps its first 180
    /// and ends with `~` and a 64-bit FNV-1a hash of the whole key (`~` is never in an escaped name).
    nonisolated static func fileName(for key: String) -> String {
        let digits = Array("0123456789ABCDEF".unicodeScalars)
        var name = String.UnicodeScalarView()
        for byte in key.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"):
                name.append(Unicode.Scalar(byte))
            default:
                name.append("_")
                name.append(digits[Int(byte >> 4)])
                name.append(digits[Int(byte & 0x0F)])
            }
        }
        if name.isEmpty { return "_" }
        guard name.count > 200 else { return String(name) }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(String(name).prefix(180)) + "~" + String(repeating: "0", count: 16 - hex.count) + hex
    }
}
