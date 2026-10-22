import Dispatch
import Foundation
import MachO
import CmuxNextCompat

/// Writes one text file per main-thread hang episode (a stall past the watchdog's hang
/// threshold, ``HangEpisodeTracker``), so the next freeze diagnoses itself:
/// `~/Library/Logs/<bundle id>/hangs/hang-<start time>.txt` with the start time, the blocked
/// duration, the app version and commit, the executable's UUID, and the main thread's stack
/// sampled while it was still blocked (then every other thread's). Debug Settings lists them.
///
/// The watchdog thread only hands over raw addresses; symbolication and file I/O run on this
/// recorder's own utility queue, so a main thread blocked in dyld or the file system never stops
/// the watchdog. The file is written when the hang starts, rewritten at the tracker's
/// checkpoints, and finalized with the exact duration when the main thread answers again.
/// Keeps the newest ``maxFiles`` files and caps each at ``maxBytes``.
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
    /// `app:` and `commit:` lines, read once from the bundle.
    private let identity: [String]
    private let isEnabled: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "cmux-next.hang-episodes", qos: .utility)
    private let state = Mutex(State())

    private struct State {
        var entries: [Entry] = []
        /// The episode being written: its beat, file and rendered stacks.
        var current: (beat: UInt64, entry: Entry, stacks: String)?
    }

    static let filePrefix = "hang-"
    static let topFrameCount = 4

    /// - Parameter isEnabled: Read when a hang starts (the Debug Settings toggle); a hang
    ///   that starts while it is off writes nothing.
    public init(directory: URL, bundle: Bundle = .main, maxFiles: Int = 20, maxBytes: Int = 64 * 1_024,
                isEnabled: @escaping @Sendable () -> Bool = { true }) {
        self.directory = directory
        self.maxFiles = max(1, maxFiles)
        self.maxBytes = max(1_024, maxBytes)
        self.isEnabled = isEnabled
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let uuid = _dyld_get_image_header(0).flatMap(AppSymbolMap.uuid(of:))?.uuidString ?? "?"
        identity = [
            "app: \(bundle.bundleIdentifier ?? "?") \(version) (\(build))",
            "commit: \(info["CMUXCommit"] as? String ?? "unknown")",
            "executable uuid: \(uuid)",
        ]
        queue.async { [self] in loadEntries() }
    }

    /// `~/Library/Logs/<bundle id>/hangs`.
    public static func defaultDirectory(bundleID: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Logs").appending(path: bundleID ?? "com.cmuxterm.app.next").appending(path: "hangs")
    }

    /// The hang files, newest first (at most ``maxFiles``). A lock and a copy.
    public var entries: [Entry] { state.withLock { $0.entries } }

    /// Posted (object: the recorder) on the recorder's queue after ``entries`` changed.
    public static let didChange = Notification.Name("cmux-next.hang-episodes.changed")

    /// The file's text, or nil when it is gone. Reads the file; call off the main thread.
    public func text(of url: URL) -> String? {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Watchdog thread

    /// A hang started `elapsed` ago: opens its file. Returns at once (the toggle is read on
    /// the recorder's queue too, so a main thread holding the tunable store's lock never
    /// blocks the watchdog).
    func begin(beat: UInt64, elapsed: Duration, main: [UInt], others: [ThreadSample]) {
        let started = Date(timeIntervalSinceNow: -elapsed.fractionalMilliseconds / 1_000)
        queue.async { [self] in
            guard isEnabled() else { return }
            let symbolicator = StackSymbolicator()
            let mainFrames = symbolicator.frames(for: main).map(\.description)
            var stacks = "main thread (innermost first):\n" + Self.lines(mainFrames)
            if !others.isEmpty {
                stacks += "\nother threads (\(others.count)):\n"
                for thread in others {
                    stacks += "thread \(thread.name.isEmpty ? "?" : thread.name):\n"
                    stacks += Self.lines(symbolicator.frames(for: thread.addresses).map(\.description))
                }
            }
            let url = directory.appending(path: Self.fileName(started))
            let entry = Entry(url: url, started: started, duration: elapsed, ongoing: true,
                              topFrames: Array(mainFrames.prefix(Self.topFrameCount)))
            state.withLock { $0.current = (beat: beat, entry: entry, stacks: stacks) }
            write(entry, stacks: stacks)
            prune()
            publish(entry)
        }
    }

    /// The hang of `beat` is still running at a checkpoint, or ended (`ongoing` false).
    func update(beat: UInt64, duration: Duration, ongoing: Bool) {
        queue.async { [self] in
            guard let current = state.withLock({ $0.current }), current.beat == beat else { return }
            var entry = current.entry
            entry.duration = duration
            entry.ongoing = ongoing
            state.withLock { state in
                if ongoing { state.current = (beat: beat, entry: entry, stacks: current.stacks) } else { state.current = nil }
            }
            write(entry, stacks: current.stacks)
            publish(entry)
        }
    }

    /// Waits for every queued write (tests).
    func drain() {
        queue.sync {}
    }

    // MARK: Recorder queue

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
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The files of earlier launches, newest first, read once at init.
    private func loadEntries() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let loaded = hangFiles().prefix(maxFiles).compactMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).flatMap { Self.parse($0, url: url) }
        }
        guard !loaded.isEmpty else { return }
        state.withLock { state in
            let fresh = Set(state.entries.map(\.url))
            state.entries = (state.entries + loaded.filter { !fresh.contains($0.url) }).sorted { $0.started > $1.started }
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func hangFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(Self.filePrefix) && $0.hasSuffix(".txt") }.sorted(by: >)
            .map { directory.appending(path: $0) }
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
