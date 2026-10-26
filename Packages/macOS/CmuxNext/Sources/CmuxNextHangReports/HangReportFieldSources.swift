import CmuxNextCompat
public import CmuxNextMetrics
public import CmuxNextTrace
public import Foundation

/// Where a schema 3 report's field data comes from (p09-observability-063): this process's metrics store and
/// its earlier launches' files (tasks 052 and 053), and the black-box rings of the app, the daemon and the
/// hosts that are still running.
///
/// Its methods read and map files, so the actor runs on a serial utility queue of its own, never on a
/// cooperative pool thread (as ``HangReportStore``). The metrics store is the one attached to `runtime` when a
/// call runs, so a store attached after launch is found.
///
/// ```swift
/// let sources = HangReportFieldSources(runtime: .shared, metricsDirectory: metricsFolder, ringDirectory: traceFolder)
/// let delta = await sources.currentDelta()
/// ```
public actor HangReportFieldSources {
    /// Whether the process `pid` that started at `startMicros` (µs since 1970) still runs.
    public typealias IsAlive = @Sendable (_ pid: Int32, _ startMicros: UInt64) -> Bool

    private let runtime: TraceRuntime
    private let metricsDirectory: URL?
    private let ringDirectory: URL?
    private let isAlive: IsAlive
    /// The actor's executor: its file work blocks this queue, not the pool.
    private nonisolated let queue = DispatchSerialQueue(label: "com.cmuxterm.app.next.hang-reports.field-data", qos: .utility)

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Makes the value from its parts.
    ///
    /// - Parameters:
    ///   - runtime: The process's trace runtime: its ring is the app's black box, its attached store the metrics.
    ///   - metricsDirectory: Where the store's launch files are (nil: no earlier launch is read).
    ///   - ringDirectory: Where the other processes' black-box files are (nil: the app's ring only).
    ///   - isAlive: Whether a ring's process still runs (tests pass their own).
    public init(runtime: TraceRuntime, metricsDirectory: URL?, ringDirectory: URL?,
                isAlive: @escaping IsAlive = { TraceRingCleanup.processIsAlive(pid: $0, startMicros: $1) }) {
        self.runtime = runtime
        self.metricsDirectory = metricsDirectory
        self.ringDirectory = ringDirectory
        self.isAlive = isAlive
    }

    private var store: MetricsStore? { MetricsStore.attached(to: runtime) }

    // MARK: Metrics

    /// This launch's samples not in a queued report yet; nil without a store or a sample.
    public func currentDelta() -> MetricsDelta? {
        guard let delta = store?.delta(), !delta.isEmpty else { return nil }
        return delta
    }

    /// `delta` (a part of ``currentDelta()``, ``HangReportBuilder/sentDelta(_:histograms:)``) is in a queued
    /// report: its samples are never sent again.
    public func markSent(_ delta: MetricsDelta) {
        store?.markLogged(delta)
    }

    /// The earlier launches' sections, oldest first. A file that does not decode is deleted (it never will).
    public func earlierLaunches() -> [MetricsLaunchSection<MetricsLaunchContents>] {
        guard let fold, let scan = try? fold.sections() else { return [] }
        for file in scan.unreadable { try? FileManager.checked.removeItem(at: file) }
        return scan.sections
    }

    /// `section` is in a queued report, or held nothing to send: its file is deleted, so it is never read again.
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

    private var fold: MetricsLaunchFold<MetricsLaunchFileReader>? {
        guard let metricsDirectory, let store else { return nil }
        return MetricsLaunchFold(directory: metricsDirectory,
                                 current: metricsDirectory.appending(path: MetricsStore.fileName(role: store.role, pid: store.pid)),
                                 reader: MetricsLaunchFileReader(role: store.role))
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
        guard let ringDirectory,
              let files = try? FileManager.checked.contentsOfDirectory(at: ringDirectory, includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.lastPathComponent.hasSuffix(".blackbox.cmxtrace") }.compactMap { file in
            guard let data = try? Data(blockingContentsOf: file), let image = TraceRing.Image(bytes: [UInt8](data)),
                  let role = TraceRuntime.Role(rawValue: image.header.roleCode), role != .app,
                  isAlive(Int32(bitPattern: image.header.pid), image.header.processStartUnixMicros) else { return nil }
            return image
        }
    }
}
