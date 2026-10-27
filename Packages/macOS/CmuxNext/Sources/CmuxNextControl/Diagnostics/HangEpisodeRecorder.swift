import Darwin
import Dispatch
public import Foundation
import MachO
import CmuxNextCompat

/// Writes one text file per main-thread hang episode (a stall past the watchdog's hang
/// threshold, ``HangEpisodeTracker``), so the next freeze diagnoses itself:
/// `~/Library/Logs/<bundle id>/hangs/hang-<start time>.txt` with the start time, the blocked
/// duration, the app version and commit, the executable's UUID and load address, and the main
/// thread's stack sampled while it was still blocked (then every other thread's). Debug Settings
/// lists them.
///
/// The watchdog thread only hands over raw addresses. File I/O runs on this recorder's own
/// utility queue: the file is written with the raw addresses as soon as the hang starts,
/// rewritten at the tracker's checkpoints, and finalized with the exact duration when the main
/// thread answers again. Symbolication (`dladdr`, which takes the loader lock a hung thread may
/// hold) runs on a second queue and only enriches the file when it finishes, so it can delay
/// neither the first write nor the final duration. Keeps the newest ``maxFiles`` files and caps
/// each at ``maxBytes``.
public final class HangEpisodeRecorder: Sendable {
    /// One hang file, for the Debug Settings list.
    public struct Entry: Sendable, Equatable {
        public var url: URL
        public var started: Date
        public var duration: Duration
        /// The file was last written while the main thread was still blocked (the app quit or
        /// was killed mid-hang, or the hang is still running).
        public var ongoing: Bool
        public var topFrames: [String]
    }

    public let directory: URL
    public let maxFiles: Int
    public let maxBytes: Int
    /// `app:`, `commit:` and executable lines, read once from the bundle at launch.
    private let identity: [String]
    private let isEnabled: @Sendable () -> Bool
    /// Return addresses to frame descriptions (``StackSymbolicator``); tests inject one.
    private let symbolicate: @Sendable ([UInt]) -> [String]
    private let queue = DispatchQueue(label: "cmux-next.hang-episodes", qos: .utility)
    private let symbolQueue = DispatchQueue(label: "cmux-next.hang-episodes.symbols", qos: .utility)
    private let state = Mutex(State())

    /// An episode whose file may still change: still blocked, or not yet symbolicated. At most
    /// ``maxFiles`` are kept, so the raw stacks waiting for symbolication stay bounded.
    private struct Episode {
        var beat: UInt64
        var entry: Entry
        var stacks: String
        /// The addresses still to symbolicate; nil once done.
        var raw: (main: [UInt], others: [ThreadSample])?
        var symbolicated: Bool { raw == nil }
    }

    private struct State {
        var entries: [Entry] = []
        var episodes: [Episode] = []
        /// One symbolication at a time: a job stuck on the loader lock holds only itself.
        var symbolicating = false
        /// The streams of ``changes()`` still iterated.
        var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
        /// How many times ``notifyChanged()`` told the subscribers (tests: one per change).
        var notifications = 0
    }

    static let filePrefix = "hang-"
    static let topFrameCount = 4

    /// - Parameter isEnabled: Read when a hang starts (the Debug Settings toggle); a hang
    ///   that starts while it is off writes nothing.
    public convenience init(directory: URL, bundle: Bundle = .main, maxFiles: Int = 20, maxBytes: Int = 64 * 1_024,
                            isEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.init(directory: directory, bundle: bundle, maxFiles: maxFiles, maxBytes: maxBytes, isEnabled: isEnabled,
                  symbolicate: { StackSymbolicator().frames(for: $0).map(\.description) })
    }

    init(directory: URL, bundle: Bundle = .main, maxFiles: Int = 20, maxBytes: Int = 64 * 1_024,
         isEnabled: @escaping @Sendable () -> Bool = { true }, symbolicate: @escaping @Sendable ([UInt]) -> [String]) {
        self.directory = directory
        self.maxFiles = max(1, maxFiles)
        self.maxBytes = max(1_024, maxBytes)
        self.isEnabled = isEnabled
        self.symbolicate = symbolicate
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let header = _dyld_get_image_header(0)
        let uuid = header.flatMap(AppSymbolMap.uuid(of:))?.uuidString ?? "?"
        let base = header.map { "0x" + String(UInt(bitPattern: $0), radix: 16) } ?? "?"
        identity = [
            "app: \(bundle.bundleIdentifier ?? "?") \(version) (\(build))",
            "commit: \(info["CMUXCommit"] as? String ?? "unknown")",
            // Raw frames in the executable resolve as address - load address against its dSYM.
            "executable: uuid \(uuid), load address \(base)",
        ]
        queue.async { [self] in loadEntries() }
    }

    /// Defense only: ends every ``changes()`` stream still registered when the recorder goes, so
    /// a subscriber that does not own the recorder stops waiting. Debug Settings holds its
    /// recorder, so its streams end when its page closes, not here; and a page keeps the recorder
    /// it opened with (``MainThreadWatchdog/episodes`` is set once, at launch). (The queued
    /// writes hold the recorder, so this runs after the last of them.)
    deinit {
        for subscriber in state.withLock({ Array($0.subscribers.values) }) { subscriber.finish() }
    }

    /// `~/Library/Logs/<bundle id>/hangs`.
    public static func defaultDirectory(bundleID: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Logs").appending(path: bundleID ?? "com.cmuxterm.app.next").appending(path: "hangs")
    }

    /// The hang files, newest first (at most ``maxFiles``). A lock and a copy.
    public var entries: [Entry] { state.withLock { $0.entries } }

    /// One element after each change of ``entries``, yielded on the recorder's queue right after
    /// the change (a hang file written or enriched, or the earlier launches' files loaded).
    /// Changes the subscriber has not taken yet fold into one pending element.
    ///
    /// Only this recorder's subscribers hear it, and only while they iterate: the stream ends,
    /// and the recorder forgets it, when the iterating task is cancelled (how a subscriber that
    /// owns the recorder ends its stream). Every stream still registered also ends if the
    /// recorder goes away. Subscribe before the
    /// change you wait for (the stream does not replay earlier changes); read ``entries`` for
    /// the list itself.
    ///
    /// ```swift
    /// let changes = recorder.changes()
    /// watch = Task { @MainActor in for await _ in changes { emit() } }
    /// ```
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        // One pending element is enough: it only says "read entries again", so changes a slow
        // subscriber has not taken yet fold into one.
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        state.withLock { $0.subscribers[id] = continuation }
        return stream
    }

    /// Streams of ``changes()`` still registered (tests: an ended stream is forgotten).
    var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    /// The changes told to the subscribers so far, each one element per stream (tests: a stream
    /// folds changes not yet taken, so only this shows a change told twice).
    var changeNotificationCount: Int { state.withLock { $0.notifications } }

    /// The text of a hang file in ``directory``: nil when it is gone, is not a regular file (a
    /// symlink is refused, never followed), or is larger than ``maxBytes``. Call off the main thread.
    public func text(of url: URL) -> String? {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return nil }
        return Self.readRegularFile(url, limit: maxBytes)
    }

    /// Whether `url` is one of this folder's hang files and a regular file (not a symlink).
    public func isHangFile(_ url: URL) -> Bool {
        var info = stat()
        return url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
            && lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    // MARK: Watchdog thread

    /// A hang started `elapsed` ago: opens its file. Returns at once (the toggle is read on
    /// the recorder's queue too, so a main thread holding the tunable store's lock never
    /// blocks the watchdog).
    func begin(beat: UInt64, elapsed: Duration, main: [UInt], others: [ThreadSample]) {
        let started = Date(timeIntervalSinceNow: -elapsed.fractionalMilliseconds / 1_000)
        queue.async { [self] in
            guard isEnabled() else { return }
            // Raw addresses first: the evidence is on disk before anything can block.
            let raw = Self.render(main: main.map(Self.hex), others: others.map { (name: $0.name, frames: $0.addresses.map(Self.hex)) })
            let entry = Entry(url: directory.appending(path: Self.fileName(started)), started: started, duration: elapsed,
                              ongoing: true, topFrames: Array(main.prefix(Self.topFrameCount).map(Self.hex)))
            state.withLock { state in
                state.episodes.append(Episode(beat: beat, entry: entry, stacks: raw, raw: (main: main, others: others)))
                // A symbolicator that never finishes leaves its episodes here; keep a bounded few.
                if state.episodes.count > maxFiles { state.episodes.removeFirst(state.episodes.count - maxFiles) }
            }
            write(entry, stacks: raw)
            prune()
            publish(entry)
            symbolicateNext()
        }
    }

    /// The hang of `beat` is still running at a checkpoint, or ended (`ongoing` false).
    func update(beat: UInt64, duration: Duration, ongoing: Bool) {
        queue.async { [self] in
            change(beat: beat) { episode in
                episode.entry.duration = duration
                episode.entry.ongoing = ongoing
            }
        }
    }

    /// Waits for every queued write, and with `symbols` every symbolication too (tests).
    func drain(symbols: Bool = true) {
        queue.sync {}
        guard symbols else { return }
        while queue.sync(execute: { state.withLock { $0.symbolicating } }) { symbolQueue.sync {} }
    }

    /// Episodes still held for their files (tests: bounded by ``maxFiles``).
    var pendingEpisodeCount: Int { state.withLock { $0.episodes.count } }

    // MARK: Recorder queue

    /// Starts symbolicating the oldest kept episode that still has raw addresses, unless a job
    /// runs. Its result enriches that episode's file; then the next one starts. Episodes dropped
    /// meanwhile are never symbolicated.
    private func symbolicateNext() {
        let next: (beat: UInt64, main: [UInt], others: [ThreadSample])? = state.withLock { state in
            guard !state.symbolicating, let episode = state.episodes.first(where: { !$0.symbolicated }),
                  let raw = episode.raw else { return nil }
            state.symbolicating = true
            return (beat: episode.beat, main: raw.main, others: raw.others)
        }
        guard let next else { return }
        symbolQueue.async { [self] in
            let mainFrames = symbolicate(next.main)
            let stacks = Self.render(main: mainFrames, others: next.others.map { (name: $0.name, frames: symbolicate($0.addresses)) })
            queue.async { [self] in
                state.withLock { $0.symbolicating = false }
                change(beat: next.beat) { episode in
                    episode.stacks = stacks
                    episode.entry.topFrames = Array(mainFrames.prefix(Self.topFrameCount))
                    episode.raw = nil
                }
                symbolicateNext()
            }
        }
    }

    /// Applies `body` to the episode of `beat` and rewrites its file; an episode that ended and
    /// is symbolicated is done and leaves the list.
    private func change(beat: UInt64, _ body: (inout Episode) -> Void) {
        let changed: Episode? = state.withLock { state in
            guard let index = state.episodes.firstIndex(where: { $0.beat == beat }) else { return nil }
            var episode = state.episodes.remove(at: index)
            body(&episode)
            if !episode.symbolicated || episode.entry.ongoing { state.episodes.insert(episode, at: index) }
            return episode
        }
        guard let changed else { return }
        write(changed.entry, stacks: changed.stacks)
        publish(changed.entry)
    }

    private func write(_ entry: Entry, stacks: String) {
        let duration = String(format: "%.3f s", entry.duration.fractionalMilliseconds / 1_000)
        var text = (["cmux main-thread hang",
                     "started: \(Self.timestamp(entry.started))",
                     "duration: \(entry.ongoing ? "at least \(duration) (still blocked when written)" : duration)",
                     "state: \(entry.ongoing ? "blocked" : "recovered")",
                     "pid: \(ProcessInfo.processInfo.processIdentifier)"] + identity).joined(separator: "\n")
        text += "\n\n" + stacks
        var data = Data(text.utf8)
        if data.count > maxBytes {
            let marker = Data("\n… truncated to \(maxBytes) bytes\n".utf8)
            data = data.prefix(maxBytes - marker.count)
            if let newline = data.lastIndex(of: UInt8(ascii: "\n")) { data = data.prefix(upTo: newline + 1) }
            data.append(marker)
        }
        // A failed write (disk full, folder removed) loses this file only; the next hang tries again.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: entry.url, options: .atomic)
    }

    /// Keeps the newest ``maxFiles`` hang files (names sort by start time).
    private func prune() {
        let files = hangFiles()
        guard files.count > maxFiles else { return }
        for url in files.dropFirst(maxFiles) { try? FileManager.default.removeItem(at: url) }
        let kept = Set(files.prefix(maxFiles))
        state.withLock { $0.entries.removeAll { !kept.contains($0.url) } }
    }

    private func publish(_ entry: Entry) {
        state.withLock { state in
            state.entries.removeAll { $0.url == entry.url }
            state.entries.insert(entry, at: 0)
            state.entries.sort { $0.started > $1.started }
            if state.entries.count > maxFiles { state.entries.removeLast(state.entries.count - maxFiles) }
        }
        notifyChanged()
    }

    /// The files of earlier launches, newest first, read once at init.
    private func loadEntries() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let loaded = hangFiles().prefix(maxFiles).compactMap { url in
            Self.readRegularFile(url, limit: maxBytes).flatMap { Self.parse($0, url: url) }
        }
        guard !loaded.isEmpty else { return }
        state.withLock { state in
            let fresh = Set(state.entries.map(\.url))
            state.entries = (state.entries + loaded.filter { !fresh.contains($0.url) }).sorted { $0.started > $1.started }
        }
        notifyChanged()
    }

    /// Tells every ``changes()`` subscriber that ``entries`` changed, on the caller's thread (the
    /// recorder's queue), outside the lock.
    private func notifyChanged() {
        let subscribers = state.withLock { state in
            state.notifications += 1
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.yield() }
    }

    /// This folder's hang files that are regular files (symlinks and folders are skipped), newest first.
    private func hangFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(Self.filePrefix) && $0.hasSuffix(".txt") }.sorted(by: >)
            .map { directory.appending(path: $0) }.filter(isHangFile)
    }

    /// Reads a regular file of at most `limit` bytes without following a symlink (`O_NOFOLLOW`).
    static func readRegularFile(_ url: URL, limit: Int) -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= off_t(limit) else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(clamping: info.st_size))
        let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count >= 0 else { return nil }
        return String(decoding: bytes.prefix(count), as: UTF8.self)
    }

    // MARK: Format

    /// `hang-2026-10-22T00-42-10.123Z.txt`: sortable, and no colons for Finder.
    static func fileName(_ date: Date) -> String {
        filePrefix + timestamp(date).replacingOccurrences(of: ":", with: "-") + ".txt"
    }

    /// UTC with milliseconds: `2026-10-22T00:42:10.123Z`.
    static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func timestamp(_ date: Date) -> String {
        date.formatted(timestampStyle)
    }

    private static func hex(_ address: UInt) -> String {
        "0x" + String(address, radix: 16)
    }

    private static func render(main: [String], others: [(name: String, frames: [String])]) -> String {
        var stacks = "main thread (innermost first):\n" + lines(main)
        if !others.isEmpty {
            stacks += "\nother threads (\(others.count)):\n"
            for thread in others {
                stacks += "thread \(thread.name.isEmpty ? "?" : thread.name):\n" + lines(thread.frames)
            }
        }
        return stacks
    }

    private static func lines(_ frames: [String]) -> String {
        frames.isEmpty ? "  (no frames)\n" : frames.enumerated().map { "  \($0.offset)  \($0.element)\n" }.joined()
    }

    /// An entry from a file's text (the header lines and the first main-thread frames).
    static func parse(_ text: String, url: URL) -> Entry? {
        var started: Date?
        var duration: Duration?
        var ongoing = false
        var frames: [String] = []
        var inMain = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("started: ") {
                started = try? Date(String(line.dropFirst(9)), strategy: timestampStyle)
            } else if line.hasPrefix("duration: ") {
                let number = line.dropFirst(10).drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
                duration = Double(number).flatMap { Int64(exactly: ($0 * 1_000).rounded()) }.map { .milliseconds($0) }
            } else if line == "state: blocked" {
                ongoing = true
            } else if line.hasPrefix("main thread") {
                inMain = true
            } else if inMain {
                guard line.hasPrefix("  "), frames.count < topFrameCount else { break }
                let trimmed = line.drop { $0 == " " }
                frames.append(String(trimmed.drop { $0.isNumber }.drop { $0 == " " }))
            }
        }
        guard let started, let duration else { return nil }
        return Entry(url: url, started: started, duration: duration, ongoing: ongoing, topFrames: frames)
    }
}
