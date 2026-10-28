import CmuxNextCompat
public import CmuxNextMetrics
public import CmuxNextTrace
import CmuxNextWakeups
public import Foundation

/// Where a schema 3 report's field data comes from: this process's metrics store and
/// its earlier launches' files (tasks 052 and 053), and the black-box rings of the app, the daemon and the
/// hosts that are still running.
///
/// Its methods read and map files, so the actor runs on a serial utility queue of its own, never on a
/// cooperative pool thread (as ``HangReportStore``). The metrics store is the one attached to `runtime` when a
/// call runs, so a store attached after launch is found; the earlier launches are read without it.
///
/// The other processes' rings are read where they write them (`<dir>/<role>-<pid>.blackbox.cmxtrace`, Rust's
/// `cmux_trace::init_blackbox`): each folder of ``RingFolders/directories`` (the app's trace folder, which task 095
/// gives the daemon and its hosts, and the daemon's `CMUX_TRACE_FLOWS` folder), and each holder's
/// `<socket>.trace` folder in ``RingFolders/holderSockets`` (`/tmp/cmux-hd-<uid>`, cmux-holder's `run`).
///
/// ```swift
/// let sources = HangReportFieldSources(runtime: .shared, metricsDirectory: metricsFolder,
///                                      rings: .init(directories: [traceFolder]))
/// let delta = await sources.currentDelta()
/// ```
public actor HangReportFieldSources {
    /// Whether the process `pid` that started at `startMicros` (µs since 1970) still runs.
    public typealias IsAlive = @Sendable (_ pid: Int32, _ startMicros: UInt64) -> Bool

    /// The folders other processes' black-box files are in.
    public struct RingFolders: Sendable, Equatable {
        /// Folders whose `*.blackbox.cmxtrace` files are read.
        public var directories: [URL]
        /// A folder of holder sockets: each `*.trace` folder in it holds one holder's rings.
        public var holderSockets: URL?

        /// Makes the value from its parts.
        public init(directories: [URL] = [], holderSockets: URL? = nil) {
            self.directories = directories
            self.holderSockets = holderSockets
        }

        /// The folders of the app with bundle id `bundleID`: its trace folder, the daemon's key-flow folder when
        /// `flowsDirectory` is set, and this user's holder socket folder.
        public static func app(bundleID: String?, flowsDirectory: URL?, uid: UInt32 = getuid(),
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> RingFolders {
            RingFolders(directories: [TraceBlackBoxFileSteps.appDirectory(bundleID: bundleID, home: home)] + [flowsDirectory].compactMap { $0 },
                        holderSockets: holderSocketDirectory(uid: uid))
        }

        /// cmux-holder's socket folder (`/tmp/cmux-hd-<uid>`, cmux-tui-core `holder_runtime::service::socket_path`).
        public static func holderSocketDirectory(uid: UInt32 = getuid()) -> URL {
            URL(filePath: "/tmp/cmux-hd-\(uid)", directoryHint: .isDirectory)
        }
    }

    /// The metrics launch-file folder of the app with bundle id `bundleID`: `~/Library/Logs/<bundle id>/metrics`,
    /// beside its trace folder (``TraceBlackBoxFileSteps/appDirectory(bundleID:home:)``), one per bundle, so a
    /// launch of the next build folds a crashed launch of this one under its own version.
    public static func appMetricsDirectory(bundleID: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Logs").appending(path: bundleID ?? "com.cmuxterm.app.next").appending(path: "metrics")
    }

    private let runtime: TraceRuntime
    /// Where the store's launch files are (nil: no earlier launch is read).
    nonisolated let metricsDirectory: URL?
    /// Where the other processes' black boxes are.
    nonisolated let rings: RingFolders
    private let isAlive: IsAlive
    /// The actor's executor: its file work blocks this queue, not the pool.
    private nonisolated let queue = DispatchSerialQueue(label: "com.cmuxterm.app.next.hang-reports.field-data", qos: .utility)

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Makes the value from its parts.
    ///
    /// - Parameters:
    ///   - runtime: The process's trace runtime: its ring is the app's black box, its attached store the metrics.
    ///   - metricsDirectory: Where the store's launch files are (nil: no earlier launch is read).
    ///   - rings: Where the other processes' black-box files are (none: the app's ring only).
    ///   - isAlive: Whether a ring's process still runs (tests pass their own).
    public init(runtime: TraceRuntime, metricsDirectory: URL?, rings: RingFolders = RingFolders(),
                isAlive: @escaping IsAlive = { TraceRingCleanup.processIsAlive(pid: $0, startMicros: $1) }) {
        self.runtime = runtime
        self.metricsDirectory = metricsDirectory
        self.rings = rings
        self.isAlive = isAlive
    }

    private var store: MetricsStore? { MetricsStore.attached(to: runtime) }

    // MARK: Metrics

    /// This launch's samples not in a queued report yet; nil without a store or a sample.
    public func currentDelta() -> MetricsDelta? {
        guard let delta = store?.delta(), !delta.isEmpty else { return nil }
        return delta
    }

    /// `delta` (a part of ``currentDelta()``, ``HangReportBuilder/sentDelta(_:histograms:)``) is in a report the
    /// server took: its samples are never sent again.
    public func markSent(_ delta: MetricsDelta) {
        store?.markLogged(delta)
    }

    /// The earlier launches' sections, oldest first. A file that does not decode is deleted (it never will).
    public func earlierLaunches() -> [MetricsLaunchSection<MetricsLaunchContents>] {
        guard let fold, let scan = try? fold.sections() else { return [] }
        for file in scan.unreadable { try? FileManager.checked.removeItem(at: file) }
        return scan.sections
    }

    /// `section` is in a report the server took, or held nothing to send: its file is deleted, so it is never read
    /// again.
    public func finished(_ section: MetricsLaunchSection<MetricsLaunchContents>) {
        try? fold?.uploaded(section)
    }

    /// Hang reports turned off: every earlier launch's file is deleted unsent (Chrome's file metrics provider
    /// deletes the files of a run whose metrics reporting is off).
    public func discardEarlierLaunches() {
        for section in earlierLaunches() { finished(section) }
    }

    /// Marks what this launch recorded so far as sent, so it never leaves: hang reports were off while it was
    /// recorded. Synchronous, for the quit path: the counters are memory (the heap or the mapped file), read
    /// and marked under the store's shadow lock, with no file call.
    public nonisolated func discardCurrent() {
        guard let store = MetricsStore.attached(to: runtime) else { return }
        store.markLogged(store.delta())
    }

    /// The fold over this process's role's launch files; this process's own file (its store's, or the one a store
    /// attached later adopts) is never an earlier launch.
    private var fold: MetricsLaunchFold<MetricsLaunchFileReader>? {
        guard let metricsDirectory else { return nil }
        let role = store?.role ?? runtime.role
        let pid = store?.pid ?? UInt32(bitPattern: getpid())
        return MetricsLaunchFold(directory: metricsDirectory,
                                 current: metricsDirectory.appending(path: MetricsStore.fileName(role: role, pid: pid)),
                                 reader: MetricsLaunchFileReader(role: role))
    }

    // MARK: Black box

    /// The records of the app's ring and of every running process's black-box file in the ring folder, through
    /// the upload decoder (``TraceBlackBoxUpload``: catalog names and numbers, no key-timing, per-key PTY or
    /// flow record, the newest ``TraceBlackBoxUpload/maxEvents``), oldest first.
    public func captureBlackBox() -> [TraceBlackBoxUpload.Record] {
        var records = runtime.ring?.decodedImage().map(TraceBlackBoxUpload.records(of:)) ?? []
        records += otherRings().flatMap(TraceBlackBoxUpload.records(of:))
        return TraceBlackBoxUpload().events(records)
    }

    /// The black boxes of the other running processes (the app's own file is its live ring, read above).
    private func otherRings() -> [TraceRing.Image] {
        let holders = rings.holderSockets.map { sockets in contents(of: sockets).filter { $0.pathExtension == "trace" } } ?? []
        let files = (rings.directories + holders).flatMap { contents(of: $0) }
        return files.filter { $0.lastPathComponent.hasSuffix(".blackbox.cmxtrace") }.compactMap { file in
            guard let data = try? Data(blockingContentsOf: file), let image = TraceRing.Image(bytes: [UInt8](data)),
                  let role = TraceRuntime.Role(rawValue: image.header.roleCode), role != .app,
                  isAlive(Int32(bitPattern: image.header.pid), image.header.processStartUnixMicros) else { return nil }
            return image
        }
    }

    /// The entries of `directory`; none when it does not exist.
    private func contents(of directory: URL) -> [URL] {
        (try? FileManager.checked.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }
}
