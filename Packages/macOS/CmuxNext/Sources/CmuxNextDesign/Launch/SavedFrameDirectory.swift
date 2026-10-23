public import Foundation
import CmuxNextCompat
import CoreGraphics
import ImageIO

/// A directory of the panes' last frames from the last quit, one image per tab key named
/// `<key>@<scale>x.<png|jpg>`: the terminals' (`TerminalLaunchFrames`) and the agent pages'
/// (`AgentPaneLaunchImages`). The launch draws each over its pane until the live content paints.
///
/// Made at the top of `main`, it lists the directory and decodes every frame on background tasks
/// at once, so the reads and the JPEG/PNG decodes overlap AppKit's start instead of running in the
/// launch window's pane builds, one per pane, before the first window frame (#17587). A pane build
/// takes its frame with ``take(_:)``: a decoded one costs nothing there. One not decoded yet is not
/// waited for: the taking thread reads it, as before there was a prefetch, the late background
/// result is dropped, and `readOnMain` hears `launch_read_on_main.<name>` when that thread is the
/// main thread (the startup bench's launch guard fails on it). Each frame is handed out once;
/// ``release()`` drops the ones no pane took once the launch settled.
///
/// ```swift
/// let frames = SavedFrameDirectory(url: state.appending(path: "terminal-launch-frames"), maximumBytes: 16 << 20,
///                                  name: "terminal_frames", readOnMain: { DebugTimings.markLaunch($0) })
/// let frame = frames.take("tab_1a2b")  // in the pane build
/// ```
public nonisolated final class SavedFrameDirectory: Sendable {
    /// The directory; nil keeps nothing (tests, previews).
    public let url: URL?
    private let maximumBytes: Int
    private let name: String
    private let readOnMain: @Sendable (String) -> Void

    private nonisolated struct State {
        /// The keys with a file, once the background listing finished.
        var listed: Set<String>?
        /// Frames decoded in the background and not taken yet.
        var decoded: [String: SavedFrame] = [:]
        /// Keys handed out or read by their taker: a late background result for one is dropped.
        var taken: Set<String> = []
        var released = false
    }

    /// The cell the decoding tasks and ``take(_:)`` share (the tasks hold it, not `self`).
    private nonisolated final class Cell: Sendable {
        // Hand-off between the decoding tasks and the synchronous `take` of a pane build, which must
        // never wait on them: a short critical section over these maps, not an actor (an await).
        let state = Mutex(State())
    }

    private let cell: Cell
    private let prefetching: Task<Void, Never>?

    /// Starts listing and decoding `url`'s frames now, on background tasks.
    /// - Parameters:
    ///   - url: The directory; nil keeps nothing.
    ///   - maximumBytes: A larger file is not read.
    ///   - name: The directory's name in the `launch_read_on_main.<name>` mark.
    ///   - readOnMain: Receives that mark when ``take(_:)`` reads a frame on the main thread.
    public init(url: URL?, maximumBytes: Int, name: String = "saved_frames",
                readOnMain: @escaping @Sendable (String) -> Void = { _ in }) {
        self.url = url
        self.maximumBytes = maximumBytes
        self.name = name
        self.readOnMain = readOnMain
        let cell = Cell()
        self.cell = cell
        guard let url else {
            cell.state.withLock { $0.listed = [] }
            prefetching = nil
            return
        }
        // task-owner: one listing and one decode per saved frame, once per launch; each file is size-capped
        prefetching = Task.detached(priority: .userInitiated) { await Self.prefetch(url, maximumBytes: maximumBytes, into: cell) }
    }

    /// Returns once the background listing and decodes finished (tests).
    package func backgroundReadFinished() async {
        await prefetching?.value
    }

    /// `key`'s frame, the first time it is asked for (nil after ``release()``).
    public func take(_ key: String) -> SavedFrame? {
        // The decoded frame, or whether this thread must read it (not decoded yet).
        let (decoded, readHere) = cell.state.withLock { state -> (SavedFrame?, Bool) in
            guard !state.released, Self.isFileSafe(key), state.taken.insert(key).inserted else { return (nil, false) }
            if let frame = state.decoded.removeValue(forKey: key) { return (frame, false) }
            return (nil, state.listed?.contains(key) ?? true)
        }
        guard readHere else { return decoded }
        guard let url, let file = Self.files(in: url, key: key).first,
              let frame = Self.decode(file.url, scale: file.scale, maximumBytes: maximumBytes) else { return nil }
        if Thread.isMainThread { readOnMain("launch_read_on_main.\(name)") }
        return frame
    }

    /// Drops the decoded frames no pane took (the launch settled); later ``take(_:)`` calls find
    /// nothing, so a pane shown later waits for its live content and nothing is read on the main thread.
    public func release() {
        cell.state.withLock { state in
            state.released = true
            state.decoded = [:]
        }
    }

    private static func prefetch(_ url: URL, maximumBytes: Int, into cell: Cell) async {
        let found = Self.files(in: url)
        cell.state.withLock { $0.listed = Set(found.keys) }
        await withTaskGroup(of: Void.self) { group in
            for (key, file) in found {
                group.addTask {
                    guard cell.state.withLock({ !$0.released && !$0.taken.contains(key) }),
                          let frame = Self.decode(file.url, scale: file.scale, maximumBytes: maximumBytes) else { return }
                    cell.state.withLock { state in
                        if !state.released, !state.taken.contains(key) { state.decoded[key] = frame }
                    }
                }
            }
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
    private static func files(in url: URL) -> [String: (url: URL, scale: Int)] {
        var best: [String: (url: URL, scale: Int, rank: Int)] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
            guard let at = name.lastIndex(of: "@") else { continue }
            let key = String(name[..<at]), suffix = name[name.index(after: at)...]
            guard isFileSafe(key), let rank = preference.firstIndex(where: { "\($0.scale)x.\($0.ext)" == suffix }),
                  best[key].map({ rank < $0.rank }) ?? true else { continue }
            best[key] = (url.appending(path: name), preference[rank].scale, rank)
        }
        return best.mapValues { ($0.url, $0.scale) }
    }

    /// `key`'s possible files in `url`, most wanted first.
    private static func files(in url: URL, key: String) -> [(url: URL, scale: Int)] {
        preference.map { (url: url.appending(path: fileName(key, scale: $0.scale, ext: $0.ext)), scale: $0.scale) }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// The decoded image of `file` (decoded now, not when it first draws).
    private static func decode(_ file: URL, scale: Int, maximumBytes: Int) -> SavedFrame? {
        guard let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, bytes <= maximumBytes,
              // concurrency-allow: one capped read of a small local image, off the main thread at launch (or by a taker that found it not read yet)
              let data = try? Data(contentsOf: file),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return SavedFrame(image: image, scale: scale)
    }
}
