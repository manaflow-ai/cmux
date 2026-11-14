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
/// utility queue, never on the main thread. Sign-out deletes them all (`removeAll`).
public final class ConversationTranscriptCache: @unchecked Sendable {
    /// Messages kept per conversation: the newest screens, not the history (older pages still
    /// come from the server when the reader scrolls up).
    public static let limit = 200

    public let directory: URL
    public let limit: Int
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

    public init(directory: URL, limit: Int = ConversationTranscriptCache.limit, writeDelay: DispatchTimeInterval = .seconds(1)) {
        self.directory = directory
        self.limit = limit
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
        try? data.write(to: file(for: key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appending(path: "\(safe.isEmpty ? "default" : safe).json")
    }
}
