public import Foundation
import CmuxNextCompat
import CoreGraphics
import ImageIO

/// A directory of the panes' last frames from the last quit, one image per tab key named
/// `<key>@<scale>x.<png|jpg>`: the terminals' (`TerminalLaunchFrames`) and the agent pages'
/// (`AgentPaneLaunchImages`). The launch draws each over its pane until the live content paints.
/// A save writes only the panes on screen at quit, so the directory holds the frames a relaunch shows.
///
/// Made at the top of `main`, it lists the directory and decodes its frames on a background task,
/// at most ``decodeWidth`` at a time, so the reads and the JPEG/PNG decodes overlap AppKit's start
/// instead of running in the launch window's pane builds, one per pane, before the first window
/// frame (#17587). A pane build takes its frame with ``take(_:)``, and each frame is read once:
/// - decoded: taken at once;
/// - being decoded: the taker waits for the rest of that decode (the decoder holds the frame's
///   `os_unfair_lock`, so the waiting thread donates its priority to it), never decodes it again;
/// - not decoded yet: the taker decodes it, and the background task skips it;
/// - listed but unreadable (larger than `maximumBytes`, corrupt): nil at once, never read again.
///
/// When the main thread waited, listed or decoded, `readOnMain` hears `launch_read_on_main.<name>`
/// (the startup bench's launch guard fails on it). ``release()`` drops the frames no pane took.
///
/// ```swift
/// let frames = SavedFrameDirectory(url: state.appending(path: "terminal-launch-frames"), maximumBytes: 16 << 20,
///                                  name: "terminal_frames", readOnMain: { DebugTimings.markLaunch($0) })
/// let frame = frames.take("tab_1a2b")  // in the pane build
/// ```
public nonisolated final class SavedFrameDirectory: Sendable {
    /// How many frames the background task decodes at once: each is a blocking read and a full
    /// decode on the cooperative pool, which the daemon connect and the launch snapshot decode need
    /// at the same moment.
    static let decodeWidth = 3

    /// The directory; nil keeps nothing (tests, previews).
    public let url: URL?
    private let maximumBytes: Int
    private let name: String
    private let readOnMain: @Sendable (String) -> Void

    private nonisolated enum Phase {
        case pending
        /// Decoded; nil when the file could not be read or decoded.
        case done(SavedFrame?)
        case taken
    }

    /// One listed frame file.
    private nonisolated final class Entry: Sendable {
        let file: URL
        let scale: Int
        // Held by whoever decodes this frame for the whole decode, so a synchronous `take` in a pane build
        // waits for the rest of it with priority donation (os_unfair_lock records its owner) instead of a
        // second decode from zero; an actor cannot serve that synchronous caller.
        let phase = Mutex(Phase.pending)

        init(file: URL, scale: Int) {
            self.file = file
            self.scale = scale
        }
    }

    private nonisolated struct State {
        /// The frames by tab key, once listed.
        var entries: [String: Entry]?
        var released = false

        /// Lists `url` unless it is listed or released; returns whether it listed now.
        mutating func listIfNeeded(_ url: URL) -> Bool {
            guard !released, entries == nil else { return false }
            entries = SavedFrameDirectory.list(url)
            return true
        }

        /// `key`'s entry, listing `url` first when nobody has (`listedHere` then becomes true).
        mutating func entry(_ key: String, listing url: URL, listedHere: inout Bool) -> Entry? {
            if listIfNeeded(url) { listedHere = true }
            return released ? nil : entries?[key]
        }
    }

    /// The cell the background task and ``take(_:)`` share (the task holds it, not `self`).
    private nonisolated final class Cell: Sendable {
        // Held for the listing (one directory read) and for short map lookups; a `take` that finds the
        // listing running waits for it with priority donation rather than listing the directory again.
        let state = Mutex(State())

        var isReleased: Bool { state.withLock { $0.released } }
    }

    private let cell: Cell
    private let prefetching: Task<Void, Never>?

    /// Starts listing and decoding `url`'s frames now, on a background task.
    /// - Parameters:
    ///   - url: The directory; nil keeps nothing.
    ///   - maximumBytes: A larger file is not read.
    ///   - name: The directory's name in the `launch_read_on_main.<name>` mark.
    ///   - readOnMain: Receives that mark when ``take(_:)`` waits, lists or decodes on the main
    ///     thread. Required, so every launch path reports its main-thread reads to the launch guard.
    public init(url: URL?, maximumBytes: Int, name: String, readOnMain: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.name = name
        self.readOnMain = readOnMain
        let cell = Cell()
        self.cell = cell
        guard let url else {
            cell.state.withLock { $0.entries = [:] }
            prefetching = nil
            return
        }
        // task-owner: one listing and one decode per saved frame (at most `decodeWidth` at once), once per launch; each file is size-capped
        prefetching = Task.detached(priority: .userInitiated) { await Self.prefetch(url, maximumBytes: maximumBytes, into: cell) }
    }

    /// Returns once the background listing and decodes finished (tests).
    package func backgroundReadFinished() async {
        await prefetching?.value
    }

    /// `key`'s frame, the first time it is asked for (nil after ``release()``).
    // perf-hot: 1ms launch-first-window (each pane build of the launch window, before its first frame, #17587)
    public func take(_ key: String) -> SavedFrame? {
        guard let url, Self.isFileSafe(key) else { return nil }
        // The calling thread waited for, listed or decoded something.
        var paid = false
        let entry: Entry?
        if let found = cell.state.withLockIfAvailable({ $0.entry(key, listing: url, listedHere: &paid) }) {
            entry = found
        } else {
            // Busy only while the background task lists the directory: wait for the rest of it.
            paid = true
            entry = cell.state.withLock { $0.entry(key, listing: url, listedHere: &paid) }
        }
        guard let entry else { return nil }
        // Busy (nil) only while the background task decodes this frame.
        if case .claimed(let frame)? = entry.phase.withLockIfAvailable({ Self.claim(&$0) }) {
            if paid { markIfOnMain() }
            return frame
        }
        // Waits for the rest of the background decode, or decodes here when it has not begun.
        markIfOnMain()
        let maximumBytes = maximumBytes
        return entry.phase.withLock { phase -> SavedFrame? in
            if case .claimed(let frame) = Self.claim(&phase) { return frame }
            phase = .taken
            return Self.decode(entry.file, scale: entry.scale, maximumBytes: maximumBytes)
        }
    }

    /// Drops the frames no pane took: later ``take(_:)`` calls find nothing, so a pane shown later
    /// waits for its live content and nothing is read on the main thread.
    public func release() {
        let entries = cell.state.withLock { state -> [Entry] in
            state.released = true
            defer { state.entries = [:] }
            return Array((state.entries ?? [:]).values)
        }
        // A decode still running sees `released` and drops its own result.
        for entry in entries { _ = entry.phase.withLockIfAvailable { $0 = .taken } }
    }

    private func markIfOnMain() {
        if Thread.isMainThread { readOnMain("launch_read_on_main.\(name)") }
    }

    private nonisolated enum Claim {
        /// The frame is the taker's (nil: unreadable, or already taken).
        case claimed(SavedFrame?)
        /// Not decoded yet.
        case pending
    }

    private static func claim(_ phase: inout Phase) -> Claim {
        switch phase {
        case .pending: return .pending
        case .done(let frame):
            phase = .taken
            return .claimed(frame)
        case .taken: return .claimed(nil)
        }
    }

    private static func prefetch(_ url: URL, maximumBytes: Int, into cell: Cell) async {
        let entries = cell.state.withLock { state -> [Entry] in
            _ = state.listIfNeeded(url)
            return state.released ? [] : (state.entries ?? [:]).sorted { $0.key < $1.key }.map(\.value)
        }
        await withTaskGroup(of: Void.self) { group in
            var queue = entries.makeIterator()
            for _ in 0..<decodeWidth {
                guard let entry = queue.next() else { break }
                group.addTask { decodeInBackground(entry, maximumBytes: maximumBytes, cell: cell) }
            }
            while await group.next() != nil {
                guard let entry = queue.next() else { continue }
                group.addTask { decodeInBackground(entry, maximumBytes: maximumBytes, cell: cell) }
            }
        }
    }

    private static func decodeInBackground(_ entry: Entry, maximumBytes: Int, cell: Cell) {
        entry.phase.withLock { phase in
            guard case .pending = phase, !cell.isReleased else { return }
            let frame = decode(entry.file, scale: entry.scale, maximumBytes: maximumBytes)
            phase = cell.isReleased ? .taken : .done(frame)
        }
    }

    // MARK: Files

    /// Replaces the saved frames in `url` with `files` (by file name, ``fileName(_:scale:ext:)``):
    /// a save replaces the whole set. Owner-only.
    public static func write(_ files: [String: Data], to url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for old in (try? manager.contentsOfDirectory(atPath: url.path)) ?? [] where files[old] == nil {
            try? manager.removeItem(at: url.appending(path: old))
        }
        for (name, data) in files {
            let file = url.appending(path: name)
            guard (try? data.write(to: file, options: [.atomic])) != nil else { continue }
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// `<key>@<scale>x.<ext>`.
    public static func fileName(_ key: String, scale: Int, ext: String) -> String { "\(key)@\(scale)x.\(ext)" }

    /// Tab keys are `tab_<hex>`; anything else never becomes a path.
    public static func isFileSafe(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 128 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    /// The scales and kinds a file may have, most wanted first (a save writes one per key).
    private static let preference: [(scale: Int, ext: String)] = [2, 1, 3].flatMap { scale in ["png", "jpg"].map { (scale, $0) } }

    /// Every key's file in `url`, the most wanted one where a key has several.
    private static func list(_ url: URL) -> [String: Entry] {
        var best: [String: (url: URL, scale: Int, rank: Int)] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
            guard let at = name.lastIndex(of: "@") else { continue }
            let key = String(name[..<at]), suffix = name[name.index(after: at)...]
            guard isFileSafe(key), let rank = preference.firstIndex(where: { "\($0.scale)x.\($0.ext)" == suffix }),
                  best[key].map({ rank < $0.rank }) ?? true else { continue }
            best[key] = (url.appending(path: name), preference[rank].scale, rank)
        }
        return best.mapValues { Entry(file: $0.url, scale: $0.scale) }
    }

    /// The decoded image of `file` (decoded now, not when it first draws).
    private static func decode(_ file: URL, scale: Int, maximumBytes: Int) -> SavedFrame? {
        guard let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, bytes <= maximumBytes,
              // concurrency-allow: one capped read of a small local image, off the main thread at launch (or by a taker that found it not decoded yet)
              let data = try? Data(contentsOf: file),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return SavedFrame(image: image, scale: scale)
    }
}
