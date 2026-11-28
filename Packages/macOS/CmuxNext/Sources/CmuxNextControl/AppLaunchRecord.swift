import CCmuxLayoutCacheFFI
public import CmuxNextWakeups
import Foundation
import os

/// Metadata supplied by the window capture owner only after publishing the image.
public struct LaunchRecordImage: Sendable {
    /// `<build>/<window_id>/<generation>`, relative to the launch image directory (launch record v2).
    public let key: String
    /// The v1 name of ``key`` (launch record v1 stored a path); kept so no caller breaks.
    @available(*, deprecated, renamed: "key")
    public var path: String { key }
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32

    public init(key: String, pixelWidth: UInt32, pixelHeight: UInt32) {
        self.key = key
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Debounced launch-record persistence shared by the app's window-record owner.
@MainActor
public final class AppLaunchRecord {
    private let bundleID: String?
    private let work: BackgroundWork
    private let restored: @MainActor () -> Bool
    private let socketPath: @MainActor () async -> String?
    private let snapshot: @MainActor ([String: LaunchRecordImage], String) -> LaunchRecordSnapshot
    private var images: [String: LaunchRecordImage] = [:]
    private lazy var writer: LaunchRecordWriter? = {
        guard let bundleID else { return nil }
        let url = LaunchTimesFile.supportDirectory(bundleID: bundleID)
            .appending(path: "launch-record.bin", directoryHint: .notDirectory)
        return LaunchRecordWriter(url: url, work: work) { [weak self] in
            guard let self else { return nil }
            let socket = await self.socketPath() ?? ""
            return self.snapshot(self.images, socket)
        }
    }()

    public init(bundleID: String?, work: BackgroundWork,
                restored: @escaping @MainActor () -> Bool,
                socketPath: @escaping @MainActor () async -> String?,
                snapshot: @escaping @MainActor ([String: LaunchRecordImage], String) -> LaunchRecordSnapshot) {
        self.bundleID = bundleID
        self.work = work
        self.restored = restored
        self.socketPath = socketPath
        self.snapshot = snapshot
    }

    public func setImage(_ image: LaunchRecordImage?, forWindow id: String) {
        images[id] = image
        schedule()
    }

    public func schedule() {
        guard restored() else { return }
        writer?.schedule()
    }

    public func flush() async {
        guard restored() else { return }
        await writer?.flush()
    }
}

/// Writes every window's layout to `<support>/layout-cache/v1.json` (cmux-layout-cache), so the
/// next launch, relaunch or restart to update draws it already placed (Leo, 2026-11-24: "it's one
/// thing to say "ok this loads faster and settles without jostling" and it's another to say "ok
/// it's already loaded""). When to write is Rust's coalescer (250 ms after the last change, at
/// most 2 s after the first): Swift notes changes, arms one DemandTimer at its next due time (no
/// polling), gathers the windows' values on the main actor, and encodes, compares and writes the
/// JSON on BackgroundWork's files lane (the main thread neither encodes nor parses it).
/// The quit and the update's relaunch flush it (`flush`, `flushNow`).
@MainActor
public final class LayoutCacheWriter {
    private let path: String?
    private let work: BackgroundWork
    private let restored: @MainActor () -> Bool
    /// Every window's values now, gathered on the main actor, as the encode of the cache's JSON
    /// (cmux-layout-cache `LayoutCache`) that runs off it; nil writes nothing.
    public typealias Snapshot = @MainActor () -> (@Sendable () -> String?)?
    private let snapshot: Snapshot
    /// The coalescer's address (0: none), a plain value, so the nonisolated deinit can free it; it
    /// is used on the main actor only (the coalescer is single-threaded).
    private let coalescerAddress: UInt
    private var coalescer: OpaquePointer? { OpaquePointer(bitPattern: coalescerAddress) }
    private let timer = DemandTimer(owner: "layout-cache.write")
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "layout-cache")
    /// The JSON last on disk and its coalescer key (`cmux_layout_cache_write_keyed`): an unchanged
    /// snapshot writes nothing, compared off the main actor. (Rust's coalescer has the same check,
    /// `needs_write`, but its C ABI joins it to the write.)
    private var lastWritten: (json: String, key: UInt64)?
    /// Counts notes, so one that lands during a write is noted again after `wrote` clears it.
    private var generation: UInt64 = 0
    private var requested = false
    private var drain: Task<Void, Never>?

    public init(bundleID: String?, work: BackgroundWork,
                restored: @escaping @MainActor () -> Bool,
                snapshot: @escaping Snapshot) {
        path = bundleID.flatMap { bundleID in
            let support = LaunchTimesFile.supportDirectory(bundleID: bundleID).path
            guard let raw = cmux_layout_cache_path(support) else { return nil }
            defer { cmux_layout_cache_string_free(raw) }
            return String(cString: raw)
        }
        self.work = work
        self.restored = restored
        self.snapshot = snapshot
        coalescerAddress = path == nil ? 0 : UInt(bitPattern: cmux_layout_cache_coalescer_new())
    }

    nonisolated deinit {
        if let coalescer = OpaquePointer(bitPattern: coalescerAddress) { cmux_layout_cache_coalescer_free(coalescer) }
    }

    /// Monotonic ms for the coalescer (its debounce, not a wall clock).
    private static func nowMs() -> UInt64 { UInt64(exactly: (ProcessInfo.processInfo.systemUptime * 1000).rounded(.down)) ?? 0 }

    /// A window's state or geometry changed (`WindowRecordSaver`): write once it settles.
    public func note() {
        guard restored(), let coalescer else { return }
        generation &+= 1
        cmux_layout_cache_coalescer_note(coalescer, Self.nowMs())
        arm()
    }

    /// One timer at the coalescer's next due time; none when nothing is pending.
    private func arm() {
        guard let coalescer else { return }
        let due = cmux_layout_cache_coalescer_next_due_ms(coalescer)
        guard due >= 0 else { return timer.cancel() }
        let wait = max(0, due - Int64(clamping: Self.nowMs()))
        timer.schedule(after: .milliseconds(wait)) { @MainActor [weak self] in self?.fire() }
    }

    private func fire() {
        guard let coalescer else { return }
        guard cmux_layout_cache_coalescer_due(coalescer, Self.nowMs()) else { return arm() }
        request()
    }

    /// The quit (`QuitCoordinator`) and the update's relaunch (`willRelaunch`) await this: what is
    /// pending is written now, after any write in flight, so an older one cannot land after it.
    public func flush() async {
        timer.cancel()
        guard restored(), let coalescer else { return }
        if cmux_layout_cache_coalescer_flush_now(coalescer) || lastWritten == nil { request() }
        await drain?.value
    }

    /// Where the caller cannot await (quit requested, update relaunch decided, `applicationWillTerminate`):
    /// a pending change is written now on the main thread (one ≤512 KiB file). With a write in
    /// flight it only asks the drain for one more, which the quit's awaited `flush` waits for (a
    /// write here could land before the older one in flight).
    public func flushNow() {
        timer.cancel()
        guard restored(), let coalescer, let path,
              cmux_layout_cache_coalescer_flush_now(coalescer) || lastWritten == nil else { return }
        guard drain == nil else { requested = true; return }
        guard let json = snapshot()?() else { return }
        var key: UInt64 = 0
        if cmux_layout_cache_write_keyed(path, json, &key) == 0 {
            lastWritten = (json, key)
            _ = cmux_layout_cache_coalescer_wrote_key(coalescer, key)
        } else {
            logger.error("layout cache write failed at quit")
        }
    }

    /// What one off-main write did (`request`).
    private enum Write: Sendable {
        case nothing
        case unchanged(key: UInt64)
        case wrote(json: String, key: UInt64)
        case failed(Int32)
    }

    private func request() {
        requested = true
        guard drain == nil else { return }
        // task-owner: drain; flush awaits it at quit and relaunch, and it releases itself after the last write.
        drain = Task { [self] in
            while requested {
                requested = false
                guard let path, let coalescer, let encode = snapshot() else { continue }
                let last = lastWritten, noted = generation
                do {
                    let outcome = try await work.run(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) { () -> Write in
                        guard let json = encode() else { return .nothing }
                        if let last, json == last.json { return .unchanged(key: last.key) }
                        var key: UInt64 = 0
                        let result = cmux_layout_cache_write_keyed(path, json, &key)
                        return result == 0 ? .wrote(json: json, key: key) : .failed(result)
                    }
                    switch outcome {
                    case .nothing: continue
                    case .unchanged(let key): _ = cmux_layout_cache_coalescer_wrote_key(coalescer, key)
                    case .wrote(let json, let key):
                        lastWritten = (json, key)
                        _ = cmux_layout_cache_coalescer_wrote_key(coalescer, key)
                        // A change noted while the file was written is not in it: note it again.
                        if generation != noted { cmux_layout_cache_coalescer_note(coalescer, Self.nowMs()) }
                        arm()
                    case .failed(let result):
                        // Still pending: the next change's note writes it again (no retry timer on a disk that refuses).
                        logger.error("layout cache write failed: \(result, privacy: .public)")
                    }
                } catch {
                    logger.error("layout cache write skipped: \(String(describing: error), privacy: .public)")
                }
            }
            drain = nil
        }
    }
}
