public import CmuxNextCompat
public import CmuxNextTrace
public import CmuxNextSettings
import Darwin
import Foundation

/// The local last-hang bundles (plans/cmux-next/chrome-parity/p09-observability.md task 125): at a hang, a copy
/// of every live process's black box, kept on this Mac for `cmux trace blackbox --last-hang N`.
///
/// A main-thread hang of ``mainThreadHang`` or more or a watched thread's hang dump (the watchdog's
/// ``MainThreadWatchdog/onLastHang``, ``attached(to:)``) or a key frame over ``slowKeyFrame``
/// (``committedKeySink(_:then:)``) calls ``trigger(_:)``: one load and one compare-exchange on the caller's thread,
/// at most once per ``minimumInterval`` one post of the copy to BackgroundWork `.files`. The copy snapshots each
/// `*.blackbox.cmxtrace` ring of a live process in the ring folders (the app's trace folder, which the daemon and
/// its children share, the terminal hosts' and each holder's) with the decode protocol
/// (``TraceRingFile/snapshot(atPath:)``), writes them with the `manifest.json` of a `cmux trace record` bundle
/// into a hidden folder, and renames it to `last-hang/1` after moving `1`...`4` one up and deleting `5`: at most
/// ``kept`` bundles, the newest first. ``captureNow(_:)`` makes the same bundle on request, each in its own folder
/// of `blackbox-now` (the newest ``nowKept`` stay). Every copy builds in its own hidden folder (pid and UUID), so
/// copies of two instances, or a hang's and a request's, never share one.
///
/// Chrome keeps the same kind of local record: its HangWatcher captures the hung thread at the hang
/// (base/threading/hang_watcher.cc) and the crash database keeps a bounded number of local reports
/// (components/crash/core/app/crashpad.cc, `crashpad::CrashReportDatabase` pruning), which
/// `chrome://crashes` lists without any upload.
///
/// ```swift
/// let bundles = LastHangBundles(traceDirectory: path, ringFolders: { _ in [path] }, work: work).attached(to: watchdog)
/// signposts.committedKey = LastHangBundles.committedKeySink(nil, then: bundles)
/// ```
public final class LastHangBundles: Sendable {
    /// The most bundles kept: `last-hang/1` (the newest) to `last-hang/5`.
    public static let kept = 5
    /// A main-thread stall this long or longer starts a bundle.
    public static let mainThreadHang: Duration = .seconds(1)
    /// A committed key whose frame took longer than this starts a bundle.
    public static let slowKeyFrame: Duration = .milliseconds(50)
    /// The least time between two hang bundles: a burst of slow frames or a hang that trips several triggers
    /// copies the rings once, and the bundles of the burst's start are not pushed out by its end.
    public static let minimumInterval: Duration = .seconds(30)
    /// ``slowKeyFrame`` in microseconds and ``minimumInterval`` in nanoseconds, as the triggers compare them.
    static let slowKeyFrameMicros: UInt64 = 50_000, minimumIntervalNanos: UInt64 = 30_000_000_000
    /// The bundles' folder in the trace folder.
    public static let folderName = "last-hang"
    /// The folder of ``captureNow(_:)``'s bundles in the trace folder.
    public static let nowFolderName = "blackbox-now"
    /// The most ``captureNow(_:)`` bundles kept: each request exports its own, so a newer request never replaces
    /// the one an earlier caller is still exporting.
    public static let nowKept = 4
    /// The wall clock in milliseconds since 1970 (the manifest's `captured_unix_ms`).
    public static let wallClockMillis: @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_REALTIME) / 1_000_000 }
    static let manifestName = "manifest.json"
    static let ringsName = "rings"
    static let ringSuffix = ".blackbox.cmxtrace"
    static let buildingPrefix = ".building-"

    /// The bundles' folder: `<trace folder>/last-hang`.
    public let directory: String
    /// ``captureNow(_:)``'s bundles: `<trace folder>/blackbox-now/<ms since 1970>-<UUID>`.
    public let nowDirectory: String
    /// Whether hangs make bundles (the `lastHangBundle` feature); ``captureNow(_:)`` and the existing bundles work
    /// either way.
    public let capturesHangs: Bool
    /// The folders whose black boxes a bundle copies, listed on `.files` at each copy (holders come and go).
    private let ringFolders: @Sendable (borrowing BlockingPermit) -> [String]
    /// This process's ring: copied from memory while it is still on the heap (its file was never made).
    private let ownRing: (ring: TraceRing, fileName: String)?
    private let work: any MayBlockRunner
    /// The monotonic clock of ``minimumInterval``, in nanoseconds.
    private let now: @Sendable () -> UInt64
    /// The wall clock of the manifest, in milliseconds since 1970.
    private let wallClock: @Sendable () -> UInt64
    /// Whether process `pid`, started at the given microseconds since 1970 (0: unknown), still runs.
    private let isAlive: @Sendable (_ pid: Int32, _ startMicros: UInt64) -> Bool
    /// When the next hang may start a bundle (``now``).
    private let nextAllowedNanos = Atomic<UInt64>(0)

    /// Bundles in `<traceDirectory>/last-hang`; nothing touches the disk until a copy runs on `work`'s `.files`.
    ///
    /// - Parameters:
    ///   - traceDirectory: The app's trace folder (``TraceBlackBox/directory``).
    ///   - ringFolders: The folders whose black boxes a bundle copies; called in the copy's `.files` body.
    ///   - ownRing: This process's black box and its file name: copied from memory when it never moved into its
    ///     file.
    ///   - work: The runner whose `.files` lane copies.
    ///   - capturesHangs: Whether ``trigger(_:)`` makes bundles (the `lastHangBundle` feature).
    ///   - now: The monotonic clock of the rate limit, in nanoseconds.
    ///   - wallClock: The wall clock of the manifest, in milliseconds since 1970.
    ///   - isAlive: Whether a ring's process still runs (``TraceRingCleanup/processIsAlive(pid:startMicros:)``).
    public init(traceDirectory: String, ringFolders: @escaping @Sendable (borrowing BlockingPermit) -> [String],
                ownRing: (ring: TraceRing, fileName: String)? = nil, work: any MayBlockRunner, capturesHangs: Bool = true,
                now: @escaping @Sendable () -> UInt64 = { TraceClock().nowNanos() },
                wallClock: @escaping @Sendable () -> UInt64 = LastHangBundles.wallClockMillis,
                isAlive: @escaping @Sendable (_ pid: Int32, _ startMicros: UInt64) -> Bool = { TraceRingCleanup.processIsAlive(pid: $0, startMicros: $1) }) {
        directory = traceDirectory + "/" + Self.folderName
        nowDirectory = traceDirectory + "/" + Self.nowFolderName
        self.ringFolders = ringFolders
        self.ownRing = ownRing
        self.work = work
        self.capturesHangs = capturesHangs
        self.now = now
        self.wallClock = wallClock
        self.isAlive = isAlive
    }

    // MARK: - Triggers (any thread)

    /// Starts a bundle for `cause` on `.files`, unless one started less than ``minimumInterval`` ago. Any thread,
    /// never waits: one load, one compare-exchange and, when it wins, one post.
    public func trigger(_ cause: LastHangCause) {
        guard capturesHangs else { return }
        let current = now()
        let next = nextAllowedNanos.load(ordering: .relaxed)
        guard current >= next,
              nextAllowedNanos.compareExchange(expected: next, desired: current &+ Self.minimumIntervalNanos, ordering: .relaxed).exchanged
        else { return }
        work.postFiles(.bestEffort, shutdown: .skipOnShutdown) { [self] permit in _ = captureLastHang(cause, permit) }
    }

    /// A committed key's `key.frame` time: past ``slowKeyFrame`` it starts a bundle. One compare otherwise.
    public func noteKeyFrame(durationMicros: UInt64) {
        guard durationMicros > Self.slowKeyFrameMicros else { return }
        trigger(.slowKeyFrame(.microseconds(Int64(clamping: durationMicros))))
    }

    /// Starts a bundle at each hang `watchdog` reports (``MainThreadWatchdog/onLastHang``) when hangs make bundles.
    ///
    /// - Returns: These bundles when they make hang bundles (for ``committedKeySink(_:then:)``); nil otherwise.
    public func attached(to watchdog: MainThreadWatchdog) -> LastHangBundles? {
        guard capturesHangs else { return nil }
        watchdog.onLastHang = { [self] cause in trigger(cause) }
        return self
    }

    /// The committed-key sink (`InputFrameSignposts.committedKey`, main thread, every committed key): `first` (hang
    /// reports' slow-frame capture), then `bundles`' ``noteKeyFrame(durationMicros:)``; nil when both are nil.
    public static func committedKeySink(_ first: ((UInt64) -> Void)?, then bundles: LastHangBundles?) -> ((UInt64) -> Void)? {
        guard let bundles else { return first }
        guard let first else { return { bundles.noteKeyFrame(durationMicros: $0) } }
        return { micros in
            first(micros)
            bundles.noteKeyFrame(durationMicros: micros)
        }
    }

    // MARK: - Copies (a `.files` body: `permit` is its permit)

    /// Copies every live black box into a new `last-hang/1`, moving the older bundles up and deleting what
    /// passes ``kept``.
    ///
    /// - Returns: The new bundle's folder; nil when nothing could be written.
    @discardableResult
    public func captureLastHang(_ cause: LastHangCause, _ permit: borrowing BlockingPermit) -> String? {
        guard let building = build(cause: cause.json, permit) else { return nil }
        return rotate(building, permit)
    }

    /// Copies every live black box into a new folder of `blackbox-now` (`cmux trace blackbox --now`), then deletes
    /// all but the newest ``nowKept`` and anything else there. Each call gets its own folder, so two requests at
    /// once never move, export or delete each other's bundle.
    ///
    /// - Returns: The bundle's folder; nil when nothing could be written.
    public func captureNow(_ permit: borrowing BlockingPermit) -> String? {
        guard let building = build(cause: nil, permit) else { return nil }
        let files = FileManager.checked
        let path = nowDirectory + "/" + Self.nowBundleName(wallClock())
        guard (try? files.createDirectory(atPath: nowDirectory, withIntermediateDirectories: true, permit,
                                          attributes: [.posixPermissions: 0o700])) != nil,
              (try? files.moveItem(atPath: building, toPath: path, permit)) != nil else {
            try? files.removeItem(atPath: building, permit)
            return nil
        }
        let names = Self.fileNames(in: nowDirectory, permit)
        let bundles = names.filter(Self.isNowBundleName)
        for name in names.filter({ !Self.isNowBundleName($0) }) + bundles.dropLast(Self.nowKept) {
            try? files.removeItem(atPath: nowDirectory + "/" + name, permit)
        }
        return path
    }

    /// The `n`-th newest bundle (1 the newest) and the cause its manifest names; nil when there is none.
    public func bundle(_ n: Int, _ permit: borrowing BlockingPermit) -> (path: String, cause: JSONValue)? {
        guard (1 ... Self.kept).contains(n) else { return nil }
        let path = slot(n)
        guard let data = FileManager.checked.contents(atPath: path + "/" + Self.manifestName, permit),
              let manifest = try? JSONValue.parse(data) else { return nil }
        return (path, manifest["cause"] ?? .null)
    }

    /// The subfolders of `parent` whose names end in `suffix` (each holder's `<socket>.trace`).
    public static func folders(in parent: String, suffix: String, _ permit: borrowing BlockingPermit) -> [String] {
        fileNames(in: parent, permit).filter { $0.hasSuffix(suffix) }.map { parent + "/" + $0 }
    }

    // MARK: - Steps

    private func slot(_ n: Int) -> String {
        directory + "/" + String(n)
    }

    /// Writes a bundle into a new hidden folder of ``directory``: each live ring under `rings/`, then the
    /// manifest. Nil when the folder or the manifest cannot be written.
    private func build(cause: JSONValue?, _ permit: borrowing BlockingPermit) -> String? {
        let files = FileManager.checked
        let folder = directory + "/" + Self.buildingPrefix + "\(getpid())-\(UUID().uuidString)"
        guard (try? files.createDirectory(atPath: folder + "/" + Self.ringsName, withIntermediateDirectories: true, permit,
                                          attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        var used = Set<String>()
        var rings: [JSONValue] = []
        for source in ringFolders(permit) {
            for name in Self.fileNames(in: source, permit) where name.hasSuffix(Self.ringSuffix) {
                guard let snapshot = TraceRingFile.snapshot(atPath: source + "/" + name),
                      isAlive(Int32(bitPattern: snapshot.pid), snapshot.processStartUnixMicros) else { continue }
                let role = snapshot.role?.fileStem ?? "unknown"
                if let entry = write(snapshot.bytes, named: name, role: role, pid: snapshot.pid, into: folder, used: &used, permit) {
                    rings.append(entry)
                }
            }
        }
        if let ownRing, !ownRing.ring.isFileBacked, !used.contains(ownRing.fileName),
           let entry = write(ownRing.ring.image(), named: ownRing.fileName, role: TraceRing.Role.app.fileStem,
                             pid: UInt32(bitPattern: getpid()), into: folder, used: &used, permit) {
            rings.append(entry)
        }
        let manifest: JSONValue = [
            "rings": .array(rings), "remotes": [], "chromium": .null, "cause": cause ?? .null,
            "captured_unix_ms": .number(Double(wallClock())),
        ]
        guard Self.writeFile(Data((manifest.prettyText() + "\n").utf8), to: folder + "/" + Self.manifestName, permit) else {
            try? files.removeItem(atPath: folder, permit)
            return nil
        }
        return folder
    }

    /// Writes one ring as `rings/<name>` (another name when two folders hold the same one); its manifest entry.
    private func write(_ bytes: [UInt8], named name: String, role: String, pid: UInt32, into folder: String,
                       used: inout Set<String>, _ permit: borrowing BlockingPermit) -> JSONValue? {
        var file = name
        var copy = 1
        while used.contains(file) {
            file = "\(copy)-\(name)"
            copy += 1
        }
        guard !bytes.isEmpty, Self.writeFile(Data(bytes), to: folder + "/" + Self.ringsName + "/" + file, permit) else { return nil }
        used.insert(file)
        return ["role": .string(role), "pid": JSONValue(Int(truncatingIfNeeded: pid)), "machine": "local", "file": .string(Self.ringsName + "/" + file)]
    }

    /// Makes `building` the newest bundle: deletes `kept`, moves each `n` to `n + 1`, moves `building` to `1`,
    /// then deletes anything else in ``directory`` but another process's copy in progress. The bundle's path.
    private func rotate(_ building: String, _ permit: borrowing BlockingPermit) -> String? {
        let files = FileManager.checked
        try? files.removeItem(atPath: slot(Self.kept), permit)
        for n in stride(from: Self.kept - 1, through: 1, by: -1) where files.fileExists(atPath: slot(n), permit) {
            if (try? files.moveItem(atPath: slot(n), toPath: slot(n + 1), permit)) == nil { try? files.removeItem(atPath: slot(n), permit) }
        }
        guard (try? files.moveItem(atPath: building, toPath: slot(1), permit)) != nil else {
            try? files.removeItem(atPath: building, permit)
            return nil
        }
        for name in Self.fileNames(in: directory, permit) where !Self.keeps(name) {
            try? files.removeItem(atPath: directory + "/" + name, permit)
        }
        return slot(1)
    }

    /// Whether ``directory`` keeps an entry named `name`: a bundle `1`...``kept``, or a copy that a running
    /// process (this one included) is still building.
    static func keeps(_ name: String) -> Bool {
        if let n = Int(name, radix: 10), (1 ... kept).contains(n), String(n) == name { return true }
        guard name.hasPrefix(buildingPrefix) else { return false }
        let pid = name.dropFirst(buildingPrefix.count).prefix { $0 != "-" }
        guard let pid = Int32(pid, radix: 10) else { return false }
        return pid == getpid() || kill(pid, 0) == 0 || errno == EPERM
    }

    /// A ``captureNow(_:)`` bundle's name: the wall clock in 16 digits, so names sort oldest first, and a UUID.
    static func nowBundleName(_ wallClockMillis: UInt64) -> String {
        let millis = String(wallClockMillis)
        return String(repeating: "0", count: max(0, nowStampDigits - millis.count)) + millis + "-" + UUID().uuidString
    }

    /// Whether `name` is a ``captureNow(_:)`` bundle's (``nowBundleName(_:)``).
    static func isNowBundleName(_ name: String) -> Bool {
        let stamp = name.utf8.prefix(nowStampDigits), rest = name.utf8.dropFirst(nowStampDigits)
        return stamp.count == nowStampDigits && stamp.allSatisfy { (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }
            && rest.first == UInt8(ascii: "-") && rest.count > 1
    }

    private static let nowStampDigits = 16

    private static func fileNames(in folder: String, _ permit: borrowing BlockingPermit) -> [String] {
        ((try? FileManager.checked.contentsOfDirectory(atPath: folder, permit)) ?? []).sorted()
    }

    /// Writes `data` to a new file at `path`; false when it exists or cannot be written.
    private static func writeFile(_ data: Data, to path: String, _ permit: borrowing BlockingPermit) -> Bool {
        (try? data.blockingWrite(to: URL(filePath: path), permit, options: .withoutOverwriting)) != nil
    }
}
