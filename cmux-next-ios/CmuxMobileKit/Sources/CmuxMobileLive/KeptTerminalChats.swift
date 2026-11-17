import Foundation
import Observation

/// What this phone keeps of Toggle Terminal and Chat for a relaunch with the Mac out of reach
/// (Leo, 2026-11-14: the phone should rely less on the Mac and on a smooth network): which acpmux
/// chat shows a terminal's harness session. With the chat's records kept by
/// `AgentTranscriptCache`, a terminal running Claude Code or Codex shows its chat's kept turns at
/// once on its chat face, offline, instead of a spinner and then the terminal.
///
/// One small JSON file beside the transcript cache's folder, keyed by account and Mac (tab and
/// session ids repeat across Macs), at most `limit` entries, newest kept. It is read
/// once off the main thread (`load()`; the first read of a key starts it) and written on the
/// transcript cache's queue. Sign-out deletes it with the transcripts (`removeAll()`).
@MainActor
@Observable
public final class KeptTerminalChats {
    struct Stamped: Codable, Equatable {
        var value: String
        var at: Double
    }

    struct Contents: Codable, Equatable {
        /// `account|mac|harness|session` -> acpmux chat id.
        var chats: [String: Stamped] = [:]
    }

    @ObservationIgnored public let file: URL
    @ObservationIgnored let limit: Int
    @ObservationIgnored private let queue: DispatchQueue
    @ObservationIgnored private let now: @Sendable () -> Date
    private var contents = Contents()
    /// The file was read (or found missing): reads answer from it.
    public private(set) var isLoaded = false
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var loadRequested = false
    /// Bumps on `removeAll`: a read that started before it never lands after it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var writeQueued = false

    nonisolated public init(file: URL, limit: Int = 512, queue: DispatchQueue,
                            now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.limit = limit
        self.queue = queue
        self.now = now
    }

    /// The parts joined by `|`, each escaped (`\` to `\\`, `|` to `\|`) so an id that holds a `|`
    /// never makes two keys one. Ids without either character keep the key they had on disk.
    public static func key(_ parts: String...) -> String? {
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return parts.map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|") }
            .joined(separator: "|")
    }

    /// Reads the file once, off the main thread. Later calls wait for the same read.
    public func load() async {
        if let loading { return await loading.value }
        let file = file, queue = queue, started = generation
        let task = Task { @MainActor [weak self] in
            let read: Contents? = await withCheckedContinuation { continuation in
                queue.async {
                    let data = try? Data(contentsOf: file)
                    continuation.resume(returning: data.flatMap { try? JSONDecoder().decode(Contents.self, from: $0) })
                }
            }
            guard let self, started == self.generation else { return }
            if let read { self.merge(read) }
            self.isLoaded = true
        }
        loading = task
        await task.value
    }

    /// The chat kept for `key`; nil until loaded or when none is kept.
    public func chat(_ key: String) -> String? {
        startLoading()
        return contents.chats[key]?.value
    }

    public func keepChat(_ chat: String?, for key: String) {
        guard contents.chats[key]?.value != chat else { return }
        contents.chats[key] = chat.map { Stamped(value: $0, at: now().timeIntervalSince1970) }
        Self.trim(&contents.chats, to: limit)
        scheduleWrite()
    }

    /// Sign-out: every pairing leaves this device.
    public func removeAll() {
        generation += 1
        contents = Contents()
        loading = nil
        loadRequested = false
        isLoaded = false
        writeQueued = false
        let file = file
        queue.async { try? FileManager.default.removeItem(at: file) }
    }

    /// A read from a view's body starts the one read; its result lands after that update.
    private func startLoading() {
        guard loading == nil, !loadRequested else { return }
        loadRequested = true
        Task { @MainActor [weak self] in await self?.load() }
    }

    /// Entries kept this run before the file was read win over the file's.
    private func merge(_ read: Contents) {
        var merged = read
        merged.chats.merge(contents.chats) { _, new in new }
        Self.trim(&merged.chats, to: limit)
        if merged != contents { contents = merged }
    }

    static func trim(_ entries: inout [String: Stamped], to limit: Int) {
        guard entries.count > limit else { return }
        for (key, _) in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(entries.count - limit) {
            entries[key] = nil
        }
    }

    /// One write per main-actor turn of changes, on the transcript cache's queue. A write waits
    /// for the read, so it never replaces the file with less than it held.
    private func scheduleWrite() {
        guard !writeQueued else { return }
        writeQueued = true
        let started = generation
        Task { @MainActor [weak self] in
            await self?.load()
            guard let self, started == self.generation else { return }
            self.write()
        }
    }

    /// Hands the contents to the queue, when a write is due.
    private func write() {
        guard writeQueued else { return }
        writeQueued = false
        let data = try? JSONEncoder().encode(contents)
        let file = file
        queue.async {
            guard let data else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Returns once every change so far is on disk (tests).
    public func flush() async {
        await load()
        write()
        let queue = queue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }
}
