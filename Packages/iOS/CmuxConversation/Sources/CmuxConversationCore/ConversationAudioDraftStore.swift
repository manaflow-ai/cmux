import Foundation
import os

/// The composer's unsent recordings (``ConversationAudioDraft``), one per
/// conversation key, kept on this device so a recording in review outlives its
/// screen, the background and the app being ended there. Reads come from
/// memory in the same run, else from disk off the main thread; writes land in
/// memory at once and on disk in order on one utility queue. Files live in
/// Application Support, readable after first unlock, out of backups.
public final class ConversationAudioDraftStore: @unchecked Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "dev.cmux.conversation.audio-drafts", qos: .utility)
    /// What this run saved or read, by key (a draft, or `.some(nil)` for "none"),
    /// and a counter ``removeAll()`` bumps: a save or read begun before it is dropped.
    private struct State {
        var drafts: [String: ConversationAudioDraft?] = [:]
        var generation = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Bumped by every ``removeAll()`` (sign-out). A recording begun under an
    /// older generation belongs to the account that left: its saves are refused.
    public var generation: Int { state.withLock { $0.generation } }

    public init(directory: URL) {
        self.directory = directory
    }

    /// The store in Application Support/`name`.
    public static func inApplicationSupport(_ name: String) -> ConversationAudioDraftStore? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return ConversationAudioDraftStore(directory: support.appendingPathComponent(name, isDirectory: true))
    }

    /// Keeps `draft` for `key`; nil forgets it (sent or thrown away). With
    /// `generation`, only while no ``removeAll()`` ran since it was read.
    public func save(_ draft: ConversationAudioDraft?, key: String, generation: Int? = nil) {
        let accepted = state.withLock { state -> Bool in
            if let generation, generation != state.generation { return false }
            state.drafts[key] = .some(draft)
            return true
        }
        guard accepted else { return }
        let url = file(for: key)
        let directory = directory
        queue.async {
            guard let draft else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(draft) else { return }
            var folder = directory
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            #if os(iOS)
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try? data.write(to: url, options: .atomic)
            #endif
        }
    }

    /// The draft kept for `key`, if any (memory first, else the file, read off the main thread).
    public func load(key: String) async -> ConversationAudioDraft? {
        let (known, generation) = state.withLock { ($0.drafts[key], $0.generation) }
        if let known { return known }
        let url = file(for: key)
        let read: ConversationAudioDraft? = await withCheckedContinuation { continuation in
            queue.async {
                let draft = (try? Data(contentsOf: url)).flatMap { try? PropertyListDecoder().decode(ConversationAudioDraft.self, from: $0) }
                continuation.resume(returning: draft)
            }
        }
        // A save made while the file was read is newer than the file.
        return state.withLock { state in
            // Everything was removed while the file was read: it is gone.
            guard state.generation == generation else { return nil }
            if let saved = state.drafts[key] { return saved }
            state.drafts[key] = .some(read)
            return read
        }
    }

    /// Sign-out: every kept recording leaves this device.
    public func removeAll() {
        state.withLock { state in
            state.drafts = [:]
            state.generation += 1
        }
        let directory = directory
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Waits until every write queued so far is on disk (tests).
    public func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    /// One file per key; the key's bytes in hex, so any key is a safe file name.
    func file(for key: String) -> URL {
        let name = key.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).plist")
    }
}
