public import CmuxNextTrace
public import Foundation
public import Sentry
import CmuxNextCompat

/// A main-thread hang that was still running when its record was last written: the
/// file ``FatalHangRecorder`` keeps on disk while the hang lasts and the next launch turns into one "fatal app
/// hang" event (``event()``) when the run did not end as asked.
///
/// The stack is stored as image UUIDs and offsets (at most ``maxImages`` images and ``maxFrames`` frames, the
/// sizes of the crash-key page's `hang_in_progress` slots), with each image's load address and `__TEXT` size
/// in the dead process, so the event's `debug_meta` maps every frame as a live hang's does
/// (``MainThreadHangEvent``). Image names are file names, never a path under the home folder. Numbers and
/// catalog names only otherwise: the attribution is a scheduled task's owner, class and `Module/File.swift:line`.
public nonisolated struct FatalHangRecord: Codable, Sendable, Equatable {
    /// One image the frames point into.
    public struct Image: Codable, Sendable, Equatable {
        /// The image's LC_UUID (36 characters, upper case).
        public var uuid: String
        /// The image's file name (`cmux`, `libsystem_kernel.dylib`).
        public var name: String
        /// Its load address in the hung process.
        public var base: UInt64
        /// Its `__TEXT` size.
        public var size: UInt64
    }

    /// One return address, innermost first.
    public struct Frame: Codable, Sendable, Equatable {
        /// The index in ``FatalHangRecord/images``; nil when no image held the address.
        public var image: Int?
        /// The offset in that image, or the raw address when ``image`` is nil.
        public var offset: UInt64
    }

    /// The record layout; a reader skips a record of another version.
    public static let currentVersion = 1
    /// The most images and frames a record keeps (the crash-key page's slots, `CrashKeySlot.hangInProgress*`).
    public static let maxImages = 16, maxFrames = 64

    public var version = FatalHangRecord.currentVersion
    /// The hung process.
    public var pid: Int32
    /// When the hang began (wall clock, seconds since 1970).
    public var startedAt: Double
    /// When it began (`CLOCK_UPTIME_RAW` nanoseconds, the crash keys' `hang_in_progress_start`).
    public var startUptimeNanos: UInt64
    /// How long it had lasted at the last write (the hang threshold, then each checkpoint).
    public var elapsedNanos: UInt64
    public var images: [Image]
    public var frames: [Frame]
    /// The main thread's phase (`cef_pump`), as the live hang event's `main_thread_phase` tag.
    public var phase: String?
    /// The scheduled task the sample caught, as the live hang event's attribution; nil sets none.
    public var owner: String?
    public var taskClass: String?
    public var location: String?
    /// The release and dist of the build that hung (the event goes out from the next launch, maybe a newer build).
    public var release: String
    public var dist: String

    /// A record of `addresses` (innermost first): each address's loaded image looked up in this process (dladdr and
    /// its load commands), so build it in the hung process, on the watchdog thread, after the sample.
    public init(pid: Int32, startedAt: Date, startUptimeNanos: UInt64, elapsedNanos: UInt64, addresses: [UInt],
                phase: String?, attribution: MainThreadHangEvent.Attribution?, release: String, dist: String) {
        self.init(pid: pid, startedAt: startedAt, startUptimeNanos: startUptimeNanos, elapsedNanos: elapsedNanos,
                  addresses: addresses, loaded: MainThreadHangEvent.images(for: addresses), phase: phase, attribution: attribution,
                  release: release, dist: dist)
    }

    /// ``init(pid:startedAt:startUptimeNanos:elapsedNanos:addresses:phase:attribution:release:dist:)`` with the images
    /// already looked up (tests plant their own).
    init(pid: Int32, startedAt: Date, startUptimeNanos: UInt64, elapsedNanos: UInt64, addresses: [UInt],
         loaded: [MainThreadHangEvent.Image], phase: String?, attribution: MainThreadHangEvent.Attribution?, release: String, dist: String) {
        var images: [Image] = []
        var frames: [Frame] = []
        for address in addresses.prefix(Self.maxFrames) {
            guard let image = loaded.first(where: { $0.contains(address) }) else {
                frames.append(Frame(image: nil, offset: UInt64(address)))
                continue
            }
            var index = images.firstIndex { $0.uuid == image.uuid && $0.base == image.base }
            if index == nil, images.count < Self.maxImages {
                let name = String(image.path.split(separator: "/").last ?? "")
                images.append(Image(uuid: image.uuid, name: name, base: image.base, size: image.size))
                index = images.count - 1
            }
            frames.append(index.map { Frame(image: $0, offset: UInt64(address) &- image.base) } ?? Frame(image: nil, offset: UInt64(address)))
        }
        self.pid = pid
        self.startedAt = startedAt.timeIntervalSince1970
        self.startUptimeNanos = startUptimeNanos
        self.elapsedNanos = elapsedNanos
        self.images = images
        self.frames = frames
        self.phase = phase
        self.owner = attribution?.owner
        self.taskClass = attribution?.taskClass
        self.location = attribution?.location
        self.release = release
        self.dist = dist
    }

    /// Whether the hang began in the run that launched at `launched` (a pid is reused, and a run that ended before
    /// writing over its file leaves an older run's record under its own pid).
    public func belongs(toRunOf pid: Int32, launchedAt launched: Date) -> Bool {
        self.pid == pid && startedAt >= launched.timeIntervalSince1970 - 1
    }

    /// The return addresses in the hung process, innermost first.
    var addresses: [UInt] {
        frames.map { frame in
            guard let index = frame.image, images.indices.contains(index) else { return UInt(truncatingIfNeeded: frame.offset) }
            return UInt(truncatingIfNeeded: images[index].base &+ frame.offset)
        }
    }

    /// The image index of a ``crashKeyFrames`` word whose address no recorded image holds (its low 48 bits are the
    /// raw address).
    public static let crashKeyNoImage = Int(UInt16.max)

    /// The frames as the crash-key page's `hang_in_progress_frames` words (`CrashKeyPage.packedFrame`): the image's
    /// index in ``images`` (high 16 bits; ``crashKeyNoImage`` for none) and the offset in it (low 48 bits).
    public var crashKeyFrames: [UInt64] {
        frames.map { CrashKeyPage.packedFrame(image: $0.image ?? Self.crashKeyNoImage, offset: $0.offset) }
    }

    /// The images' UUIDs as the crash-key page's `hang_in_progress_images` words: two per image in ``images``' order,
    /// each UUID's 16 bytes as two little-endian words (as the page header's build UUID).
    public var crashKeyImageUUIDWords: [UInt64] {
        images.flatMap { Self.uuidWords($0.uuid) }
    }

    /// The 16 bytes of a UUID string as two little-endian words; zeros when it is not 32 hex digits.
    static func uuidWords(_ uuid: String) -> [UInt64] {
        let digits = uuid.compactMap(\.hexDigitValue)
        guard digits.count == 32 else { return [0, 0] }
        let bytes = stride(from: 0, to: 32, by: 2).map { UInt64(digits[$0] << 4 | digits[$0 + 1]) }
        return [0, 8].map { start in (0 ..< 8).reduce(UInt64(0)) { word, index in word | bytes[start + index] << (8 * UInt64(index)) } }
    }

    /// The images as the live hang event describes them.
    var eventImages: [MainThreadHangEvent.Image] {
        images.map { MainThreadHangEvent.Image(base: $0.base, size: $0.size, uuid: $0.uuid, path: $0.name) }
    }

    /// The "fatal app hang" event: level fatal, one unhandled `FatalAppHang` exception with the main thread's stack
    /// (the crashed main thread), the images as `debug_meta`, the hang's start as the timestamp, the hung build's
    /// release, and the live hang event's tags (`hang_source`, `main_thread_phase`, `hang_owner`, `hang_class`)
    /// plus `hang_fatal`.
    public func event() -> Event {
        let event = Event(level: .fatal)
        event.platform = "cocoa"
        event.timestamp = Date(timeIntervalSince1970: startedAt)
        event.releaseName = release
        event.dist = dist
        let seconds = elapsedNanos / 1_000_000_000
        let hang = Exception(value: "main thread busy for at least \(seconds) s when the app ended", type: "FatalAppHang")
        let mechanism = Mechanism(type: "main_thread_watchdog")
        mechanism.handled = false
        hang.mechanism = mechanism
        let images = eventImages
        let stacktrace = MainThreadHangEvent.stacktrace(addresses, images: images, packages: true)
        hang.stacktrace = stacktrace
        hang.threadId = NSNumber(value: 0)
        let main = SentryThread(threadId: NSNumber(value: 0))
        main.name = "main"
        main.isMain = NSNumber(value: true)
        main.current = NSNumber(value: true)
        main.crashed = NSNumber(value: true)
        main.stacktrace = stacktrace
        event.exceptions = [hang]
        event.threads = [main]
        event.debugMeta = MainThreadHangEvent.debugMeta(images)
        event.tags = ["hang_source": "main_thread_watchdog", "hang_fatal": "true"]
        if let phase { event.tags?["main_thread_phase"] = phase }
        if let owner { event.tags?["hang_owner"] = owner }
        if let taskClass { event.tags?["hang_class"] = taskClass }
        event.extra = ["hang_ms": Int(clamping: elapsedNanos / 1_000_000)]
        if let location { event.extra?["hang_location"] = location }
        return event
    }

    /// The record in `url` (its JSON), then the file removed, so a record is reported at most once; nil when there is
    /// none, it does not decode or it has another layout version. Blocking file work: BackgroundWork `.files`.
    public static func take(at url: URL) -> FatalHangRecord? {
        guard let data = try? Data(blockingContentsOf: url) else { return nil }
        // SAFETY: blockingUnlink reads the NUL-terminated copy of the path Swift makes for the call.
        _ = unsafe blockingUnlink(url.path)
        guard let record = try? JSONDecoder().blockingDecode(FatalHangRecord.self, from: data),
              record.version == currentVersion else { return nil }
        return record
    }
}

extension FatalHangRecord {
    /// The hung run's black box (its `app-<pid>.blackbox.cmxtrace` in `traceDirectory`, which the next launch's
    /// cleanup keeps for days) through the upload decoder (``TraceBlackBoxUpload``): catalog names and numbers only,
    /// the newest ``TraceBlackBoxUpload/maxEvents``. Empty when the file is gone, is not a v1 ring or is another
    /// run's (a reused pid). Blocking file work: BackgroundWork `.files`.
    public func blackBoxRecords(traceDirectory: URL) -> [TraceBlackBoxUpload.Record] {
        let path = traceDirectory.appending(path: TraceRingFile.fileName(role: .app, pid: UInt32(bitPattern: pid)))
        guard let data = try? Data(blockingContentsOf: path), let image = TraceRing.Image(bytes: [UInt8](data)),
              image.header.pid == UInt32(bitPattern: pid),
              Double(image.header.startUnixNanos) / 1_000_000_000 <= startedAt else { return [] }
        return TraceBlackBoxUpload().events(TraceBlackBoxUpload.records(of: image))
    }
}

extension CrashReporter {
    /// Sends one event with the scope it goes out with (Sentry's `capture(event:scope:)`); tests pass their own.
    public typealias ScopedCapture = @Sendable (Event, Scope) -> Void

    /// Sentry's capture with the given scope.
    public static let sentryCapture: ScopedCapture = { SentrySDK.capture(event: $0, scope: $1) }

    /// Sends the previous run's fatal app hang (``FatalHangRecord/event()``), with the run's black box as
    /// `blackbox.txt` when one is given (``blackboxAttachment(_:hangReportsOptIn:scrubber:)``). Does nothing while crash
    /// reporting is off.
    public nonisolated func reportFatalHang(_ record: FatalHangRecord, blackbox: Attachment?,
                                            capture: ScopedCapture = CrashReporter.sentryCapture) {
        guard isStarted else { return }
        Self.sendFatalHang(record, blackbox: blackbox, capture: capture)
    }

    /// Captures `record`'s event with a clean scope, as the helper-crash forwarders do (`SystemCrashForwarder`):
    /// this launch's breadcrumbs, tags and contexts (its app version and build) do not describe the run that hung.
    static func sendFatalHang(_ record: FatalHangRecord, blackbox: Attachment?, capture: ScopedCapture) {
        let scope = Scope()
        if let blackbox { scope.addAttachment(blackbox) }
        capture(record.event(), scope)
    }
}
