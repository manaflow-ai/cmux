public import Foundation
import CmuxNextCompat
import CoreGraphics
import ImageIO

/// A directory of the panes' last frames from the last quit, one image per tab key named
/// `<key>@<scale>x.<png|jpg>`: the terminals' (`TerminalLaunchFrames`) and the agent pages'
/// (`AgentPaneLaunchImages`). The launch draws each over its pane until the live content paints.
/// A save writes only the panes on screen at quit, so the directory holds the frames a relaunch
/// shows, no more.
///
/// Made at the top of `main`, it lists the directory and decodes its frames on one reader of its
/// own (a serial dispatch queue, one decode per block), so the reads and the JPEG/PNG decodes
/// overlap AppKit's start and the window build instead of running in the pane builds, and never
/// block the Swift cooperative pool the daemon connect needs at the same moment (#17587). The
/// panes a pane build asked for go first, then the frames the first windows show
/// (``prioritize(_:)``, from the launch snapshot), then the rest.
///
/// The hand-off never blocks the main thread. ``take(_:whenDecoded:)`` returns a decoded frame at
/// once; a frame the reader has not decoded yet goes to its pane later, on the main actor, as soon
/// as it is decoded (the pane draws without it until then, and a pane whose live content painted
/// first ignores it). It is bounded: one decoded frame per listed file and at most one waiting
/// pane per frame (each frame is handed out once); ``release()`` drops what no pane took.
///
/// ```swift
/// let frames = SavedFrameDirectory(url: state.appending(path: "terminal-launch-frames"), maximumBytes: 16 << 20)
/// frames.prioritize(snapshot.shownTabKeys)            // once the launch snapshot is read
/// if let frame = frames.take("tab_1a2b", whenDecoded: { show($0) }) { show(frame) }  // in the pane build
/// ```
public final class SavedFrameDirectory: Sendable {
    /// The directory; nil keeps nothing (tests, previews).
    public let url: URL?
    /// Reads and decodes one frame file at its scale (an ImageIO decode; tests pass a slow or failing one).
    private let decodeFile: @Sendable (URL, Int) -> SavedFrame?
    // A compare-and-set over the listing, each frame's phase and its one waiter, from the pane
    // builds and the reader's blocks: the lock carve-out (CLAUDE.md). Held only to move a frame or a
    // waiter between phases, never across a file read or a decode, and nobody waits for the reader.
    private let state = Mutex(SavedFrameDirectoryState())
    /// The reader: lists the directory, then decodes one frame per block. A dispatch queue, not a
    /// task: each decode blocks on a file read, which belongs off the cooperative pool.
    private let reader: DispatchQueue

    /// Starts listing and decoding `url`'s frames now, on the reader.
    /// - Parameters:
    ///   - url: The directory; nil keeps nothing.
    ///   - maximumBytes: A larger file is not read.
    ///   - name: The directory's name in the reader's queue label (`terminal_frames`, `agent_page_images`).
    public convenience init(url: URL?, maximumBytes: Int, name: String = "frames") {
        self.init(url: url, name: name) { file, scale in SavedFrameDirectory.decode(file, scale: scale, maximumBytes: maximumBytes) }
    }

    /// Starts listing `url` now and decoding its frames with `decode`, on the reader (tests).
    package init(url: URL?, name: String, decode: @escaping @Sendable (URL, Int) -> SavedFrame?) {
        self.url = url
        decodeFile = decode
        // concurrency-allow: the one reader of a launch's frame files (work delivery, not a lock on state); nothing ever waits for it
        reader = DispatchQueue(label: "com.cmuxterm.saved-frames.\(name)", qos: .userInitiated)
        guard let url else {
            state.withLock { $0.listed([:]) }
            return
        }
        reader.async { [self] in
            let found = Self.list(url)
            state.withLock { $0.listed(found) }
            decodeNext()
        }
    }

    /// Decodes `keys` (tab keys, front window first) before every frame no pane asked for: the
    /// panes the launch's first windows build. Keys already decoded or claimed keep their phase.
    public func prioritize(_ keys: [String]) {
        state.withLock { $0.prioritize(keys) }
    }

    /// `key`'s frame, the first time it is asked for: decoded, it is returned now; not decoded yet,
    /// nil is returned now and `whenDecoded` gets it on the main actor once the reader decoded it
    /// (never when there is no such file, its decode failed, or ``release()`` came first). Never
    /// waits.
    /// - Parameters:
    ///   - key: The tab key.
    ///   - whenDecoded: The pane's later delivery; it checks that its pane still wants the frame.
    // perf-hot: 1ms launch-first-window (each pane build of the launch window, before its first frame, #17587)
    public func take(_ key: String, whenDecoded: @escaping @MainActor @Sendable (SavedFrame) -> Void) -> SavedFrame? {
        guard url != nil, Self.isFileSafe(key) else { return nil }
        let claim = state.withLock { $0.claim(key, waiter: whenDecoded) }
        if case .frame(let frame) = claim { return frame }
        return nil
    }

    /// Drops the frames no pane took and the panes still waiting: later takes find nothing, so a
    /// pane shown later waits for its live content; the reader starts no other decode.
    public func release() {
        let idle = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.release()
            return state.takeIdleWaiters()
        }
        for waiter in idle { waiter.resume() }
    }

    /// Returns once the reader has nothing left to decode (tests).
    package func readerIdle() async {
        await withCheckedContinuation { (idle: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                guard !state.isIdle else { return true }
                state.idleWaiters.append(idle)
                return false
            }
            if now { idle.resume() }
        }
    }

    /// Claims the next frame and decodes it in this reader block; the next block decodes the one
    /// after it (one decode per block, so a pane's ask reorders the queue between two decodes).
    private func decodeNext() {
        guard let next = state.withLock({ $0.claimNext() }) else {
            let idle = state.withLock { $0.takeIdleWaiters() }
            for waiter in idle { waiter.resume() }
            return
        }
        let frame = decodeFile(next.entry.file, next.entry.scale)
        let (delivery, idle) = state.withLock { state in (state.decoded(next.key, frame), state.takeIdleWaiters()) }
        if let delivery {
            let (waiter, decoded) = delivery
            // task-owner: one main-actor delivery of one decoded frame; it ends once the pane drew it or declined it
            Task { @MainActor in waiter(decoded) }
        }
        for waiter in idle { waiter.resume() }
        reader.async { [self] in decodeNext() }
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

    /// The decoded image of `file` (decoded now, so drawing it costs no decode on the main thread).
    private static func decode(_ file: URL, scale: Int, maximumBytes: Int) -> SavedFrame? {
        guard let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, bytes <= maximumBytes,
              // concurrency-allow: one capped read of a small local image, on the reader
              let data = try? Data(contentsOf: file),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return SavedFrame(image: image, scale: scale)
    }
}
