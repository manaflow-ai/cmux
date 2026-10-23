public import Foundation
import CmuxNextCompat
import CoreGraphics
import ImageIO

/// A directory of the panes' last frames from the last quit, one image per tab key named
/// `<key>@<scale>x.<png|jpg>`: the terminals' (`TerminalLaunchFrames`) and the agent pages'
/// (`AgentPaneLaunchImages`). The launch draws each over its pane until the live content paints.
/// A save writes only the panes on screen at quit, so the directory holds the frames a relaunch shows.
///
/// Made at the top of `main`, it lists the directory and decodes its frames on ``decodeWidth``
/// serial dispatch queues of its own (lanes), one decode per block, so the reads and the JPEG/PNG
/// decodes overlap AppKit's start instead of running in the launch window's pane builds, and never
/// block the Swift cooperative pool the daemon connect needs at the same moment (#17587). The frames
/// the first window shows go first (``prioritize(_:)``, from the launch snapshot). No lock is held
/// while a file is read or decoded; the lock only moves a frame between phases.
///
/// A pane build takes its frame with ``take(_:)``, and each frame is decoded once:
/// - decoded: taken at once;
/// - being decoded by a lane: the taker waits for that one decode (an empty `sync` on the lane,
///   which raises the lane to the taker's QoS), never decodes it again;
/// - not decoded yet: the taker claims it and decodes it itself (faster than waiting for a lane
///   busy with other frames), and no lane decodes it;
/// - listed but unreadable (larger than `maximumBytes`, corrupt): nil at once, never read again.
///
/// When the main thread waited, listed or decoded, `readOnMain` hears `launch_read_on_main.<name>`
/// (the startup bench's launch guard fails on it). ``release()`` drops the frames no pane took.
///
/// ```swift
/// let frames = SavedFrameDirectory(url: state.appending(path: "terminal-launch-frames"), maximumBytes: 16 << 20,
///                                  name: "terminal_frames", readOnMain: { DebugTimings.markLaunch($0) })
/// frames.prioritize(snapshot.shownTabKeys)  // once the launch snapshot is read
/// let frame = frames.take("tab_1a2b")       // in the pane build
/// ```
public final class SavedFrameDirectory: Sendable {
    /// How many frames decode at once: each is a blocking read and a full decode, beside the
    /// daemon connect and the launch snapshot decode.
    static let decodeWidth = 3

    /// The directory; nil keeps nothing (tests, previews).
    public let url: URL?
    private let maximumBytes: Int
    private let name: String
    private let readOnMain: @Sendable (String) -> Void
    // A compare-and-set over the listing and each frame's phase, from synchronous pane builds and
    // the lanes: the lock carve-out (CLAUDE.md). Held only to move a frame between phases (and to
    // enqueue a lane's next block, so a waiter never queues ahead of the decode it waits for),
    // never across a file read or a decode.
    private let state = Mutex(SavedFrameDirectoryState())
    /// The decode lanes; lane 0 lists the directory first. Dispatch queues, not tasks: each decode
    /// blocks on I/O, and a synchronous take waits for exactly one lane's block with QoS donation.
    private let lanes: [DispatchQueue]
    // concurrency-allow: counts the listing and decode blocks for tests' backgroundReadFinished (notify only, never waited on)
    private let work = DispatchGroup()

    /// What a take does after one look at the frame's phase.
    private enum TakeStep: Sendable {
        case frame(SavedFrame?)
        case decode(URL, scale: Int)
        case wait(lane: Int)
    }

    /// Starts listing and decoding `url`'s frames now, on background lanes.
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
        // concurrency-allow: serial queues for blocking launch-file decodes (work delivery, not a lock on state); a take waits for one decode block
        lanes = (0..<Self.decodeWidth).map { DispatchQueue(label: "com.cmuxterm.saved-frames.\(name).\($0)", qos: .userInitiated) }
        guard let url else {
            state.withLock { $0.listed([:]) }
            return
        }
        work.enter()
        lanes[0].async { [self] in
            let found = Self.list(url)
            state.withLock { $0.listed(found) }
            for lane in lanes.indices { decodeNext(on: lane) }
            work.leave()
        }
    }

    /// Returns once the listing and every background decode finished (tests). Each block enqueues
    /// its successor before it leaves `work`, so the count reaches zero only when all are done.
    package func backgroundReadFinished() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            work.notify(queue: lanes[0]) { done.resume() }
        }
    }

    /// Decodes `keys` (tab keys, front window first) before every other frame: the panes the
    /// launch's first windows build. Keys already decoded or claimed keep their phase.
    public func prioritize(_ keys: [String]) {
        state.withLock { $0.prioritize(keys) }
    }

    /// `key`'s frame, the first time it is asked for (nil after ``release()``).
    // perf-hot: 1ms launch-first-window (each pane build of the launch window, before its first frame, #17587)
    public func take(_ key: String) -> SavedFrame? {
        guard url != nil, Self.isFileSafe(key) else { return nil }
        // One mark per take, however many waits it had.
        var marked = false
        func markOnce() {
            if !marked { markIfOnMain() }
            marked = true
        }
        if state.withLock({ $0.entries == nil }) {
            // The listing is lane 0's first block: wait for it.
            markOnce()
            // concurrency-allow: waits for lane 0's listing block (one directory read), not a lock on state; dispatch_sync donates the caller's QoS
            lanes[0].sync {}
        }
        let next = state.withLock { state -> TakeStep in
            guard var entry = state.entries?[key] else { return .frame(nil) }
            switch entry.phase {
            case .done(let frame):
                entry.phase = .taken
                state.entries?[key] = entry
                return .frame(frame)
            case .taken:
                return .frame(nil)
            case .pending:
                entry.phase = .taken
                state.entries?[key] = entry
                return .decode(entry.file, scale: entry.scale)
            case .decoding(let lane):
                return .wait(lane: lane)
            }
        }
        switch next {
        case .frame(let frame):
            return frame
        case .decode(let file, let scale):
            markOnce()
            return Self.decode(file, scale: scale, maximumBytes: maximumBytes)
        case .wait(let lane):
            markOnce()
            // concurrency-allow: waits for the one decode block running on this lane (enqueued before the lane's next), not a lock on state; dispatch_sync donates the caller's QoS
            lanes[lane].sync {}
            return state.withLock { state -> SavedFrame? in
                guard var entry = state.entries?[key], case .done(let frame) = entry.phase else { return nil }
                entry.phase = .taken
                state.entries?[key] = entry
                return frame
            }
        }
    }

    /// Drops the frames no pane took: later ``take(_:)`` calls find nothing, so a pane shown later
    /// waits for its live content and nothing is read on the main thread; no lane starts a decode.
    public func release() {
        state.withLock { $0.release() }
    }

    private func markIfOnMain() {
        if Thread.isMainThread { readOnMain("launch_read_on_main.\(name)") }
    }

    /// Claims the next frame for `lane` and enqueues its decode there (under the lock, so a taker
    /// that sees the claim queues its wait behind that decode); the decode enqueues the next.
    private func decodeNext(on lane: Int) {
        state.withLock { current in
            guard let (key, entry) = current.claimNext(lane: lane) else { return }
            work.enter()
            lanes[lane].async { [self] in
                let frame = Self.decode(entry.file, scale: entry.scale, maximumBytes: maximumBytes)
                state.withLock { $0.decoded(key, frame) }
                decodeNext(on: lane)
                work.leave()
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
    private static func list(_ url: URL) -> [String: SavedFrameDirectoryState.Entry] {
        var best: [String: (url: URL, scale: Int, rank: Int)] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
            guard let at = name.lastIndex(of: "@") else { continue }
            let key = String(name[..<at]), suffix = name[name.index(after: at)...]
            guard isFileSafe(key), let rank = preference.firstIndex(where: { "\($0.scale)x.\($0.ext)" == suffix }),
                  best[key].map({ rank < $0.rank }) ?? true else { continue }
            best[key] = (url.appending(path: name), preference[rank].scale, rank)
        }
        return best.mapValues { SavedFrameDirectoryState.Entry(file: $0.url, scale: $0.scale) }
    }

    /// The decoded image of `file` (decoded now, not when it first draws).
    private static func decode(_ file: URL, scale: Int, maximumBytes: Int) -> SavedFrame? {
        guard let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, bytes <= maximumBytes,
              // concurrency-allow: one capped read of a small local image, on a decode lane (or by a taker that claimed it before any lane)
              let data = try? Data(contentsOf: file),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return SavedFrame(image: image, scale: scale)
    }
}
