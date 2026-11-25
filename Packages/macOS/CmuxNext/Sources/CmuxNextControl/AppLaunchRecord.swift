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
/// polling), takes the snapshot on the main actor and writes it on BackgroundWork's files lane.
/// The quit and the update's relaunch flush it (`flush`, `flushNow`).
@MainActor
public final class LayoutCacheWriter {
    private let path: String?
    private let work: BackgroundWork
    private let restored: @MainActor () -> Bool
    /// The cache's JSON (cmux-layout-cache `LayoutCache`) for every window now; nil writes nothing.
    private let snapshot: @MainActor () -> String?
    /// The coalescer's address (0: none), a plain value, so the nonisolated deinit can free it; it
    /// is used on the main actor only (the coalescer is single-threaded).
    private let coalescerAddress: UInt
    private var coalescer: OpaquePointer? { OpaquePointer(bitPattern: coalescerAddress) }
    private let timer = DemandTimer(owner: "layout-cache.write")
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "layout-cache")
    /// The JSON last on disk: an unchanged snapshot writes nothing. (Rust's coalescer has the same
    /// check, `needs_write`, but its C ABI joins it to the write; TODO: call it once it is exported.)
    private var lastWritten: String?
    /// Counts notes, so one that lands during a write is noted again after `wrote` clears it.
    private var generation: UInt64 = 0
    private var requested = false
    private var drain: Task<Void, Never>?

    public init(bundleID: String?, work: BackgroundWork,
                restored: @escaping @MainActor () -> Bool,
                snapshot: @escaping @MainActor () -> String?) {
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
        guard let json = snapshot() else { return }
        switch cmux_layout_cache_coalescer_write(coalescer, path, json) {
        case 1, 0: lastWritten = json
        default: logger.error("layout cache write failed at quit")
        }
    }

    private func request() {
        requested = true
        guard drain == nil else { return }
        // task-owner: drain; flush awaits it at quit and relaunch, and it releases itself after the last write.
        drain = Task { [self] in
            while requested {
                requested = false
                guard let path, let coalescer, let json = snapshot() else { continue }
                if json == lastWritten {
                    _ = cmux_layout_cache_coalescer_wrote(coalescer, json)
                    continue
                }
                let noted = generation
                do {
                    let result = try await work.run(.bestEffort, mayBlock: .files, shutdown: .blockShutdown) {
                        cmux_layout_cache_write(path, json)
                    }
                    if result == 0 {
                        lastWritten = json
                        _ = cmux_layout_cache_coalescer_wrote(coalescer, json)
                        // A change noted while the file was written is not in it: note it again.
                        if generation != noted { cmux_layout_cache_coalescer_note(coalescer, Self.nowMs()) }
                        arm()
                    } else {
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
