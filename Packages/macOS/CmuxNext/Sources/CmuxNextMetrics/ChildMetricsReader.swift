public import CmuxNextCompat
public import CmuxNextTrace
import Darwin
public import Foundation

/// Reads a child process's metrics file (`metrics-<role>-<pid>.bin`, task 131's Rust writer with
/// ``MetricsStore``'s layout) read-only, net of what the app already folded from it.
///
/// The app never writes a child's file, so it keeps its own cursor beside it: `metrics-<role>-<pid>.folded`, the
/// cumulative numbers it folded so far from that source launch. ``read(_:)`` gives the file's unsent samples minus
/// the cursor, for both readers of a child's file:
/// - while the child runs, ``DaemonMetricsFold`` folds that remainder into the app's own histograms at a report and
///   advances the cursor (``advance(_:launch:by:)``), so an app relaunch over the same daemon folds nothing twice;
/// - after the child died, ``MetricsLaunchFold`` with this reader sends the rest as the child's own section under its
///   own profile, and ``isLaunchFile(_:)`` keeps a running child's file out of that fold.
///
/// Chrome's model: the browser maps each child's persistent histogram memory and merges only its deltas
/// (`SubprocessMetricsProvider::MergeHistogramDeltasFromAllocator`, components/metrics/content/subprocess_metrics_provider.cc),
/// and a dead child's file is read once by `FileMetricsProvider` (components/metrics/file_metrics_provider.cc).
///
/// Every call reads or writes files: call it off the main thread (BackgroundWork `.files`).
///
/// ```swift
/// let reader = ChildMetricsReader(role: .daemon, directory: traceFolder)
/// let fold = MetricsLaunchFold(directory: traceFolder, current: reader.file(pid: livePID), reader: reader)
/// ```
public struct ChildMetricsReader: MetricsLaunchReading {
    /// The child process kind whose files are read.
    public let role: TraceRuntime.Role
    /// The folder of the child's metrics files.
    public let directory: URL
    /// Whether the process with a pid runs now (its file belongs to the live fold, not to the dead-file fold).
    private let isRunning: @Sendable (UInt32) -> Bool
    private let files: MetricsLaunchFileReader

    /// The suffix of a cursor file.
    static let cursorExtension = "folded"

    /// A reader of `role`'s files in `directory`.
    ///
    /// - Parameter isRunning: Whether a pid's process runs; ``processIsRunning(_:)`` when nil (tests pass their own).
    public init(role: TraceRuntime.Role, directory: URL, isRunning: (@Sendable (UInt32) -> Bool)? = nil) {
        self.role = role
        self.directory = directory
        if let isRunning {
            self.isRunning = isRunning
        } else {
            self.isRunning = { pid in ChildMetricsReader.processIsRunning(pid) }
        }
        files = MetricsLaunchFileReader(role: role)
    }

    /// Whether the process `pid` exists (`kill(pid, 0)`; EPERM is another user's live process).
    public static func processIsRunning(_ pid: UInt32) -> Bool {
        guard let pid = Int32(exactly: pid), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The metrics file of `role` in process `pid`.
    public func file(pid: UInt32) -> URL {
        directory.appending(path: MetricsStore.fileName(role: role, pid: pid), directoryHint: .notDirectory)
    }

    /// Whether `file` is a dead child's metrics file of this role: a running child's file is folded live.
    public func isLaunchFile(_ file: URL) -> Bool {
        guard files.isLaunchFile(file), let pid = Self.pid(of: file) else { return false }
        return !isRunning(pid)
    }

    /// Whether `file` exists.
    public func exists(_ file: URL) -> Bool {
        FileManager.checked.fileExists(atPath: file.path(percentEncoded: false))
    }

    /// `file`'s unsent samples minus what the cursor says the app folded already, under the file's own profile and
    /// source launch id. Throws ``MetricsLaunchFoldError/unreadable(_:)`` when the file or its cursor does not decode.
    public func read(_ file: URL) throws(MetricsLaunchFoldError) -> MetricsLaunchContents {
        let contents = try files.read(file)
        guard let folded = try cursor(of: file), folded.launch == contents.id else { return contents }
        var delta = contents.delta
        delta.histograms = delta.histograms.compactMap { histogram -> MetricsDelta.Histogram? in
            guard let counts = folded.histograms[histogram.name] else { return histogram }
            return histogram.minus(counts)
        }
        return MetricsLaunchContents(id: contents.id, delta: delta)
    }

    /// Adds `histograms` (read from `file` by ``read(_:)``) to the file's cursor, written atomically, so a later
    /// ``read(_:)`` of the same source launch leaves them out.
    public func advance(_ file: URL, launch: String, by histograms: [MetricsDelta.Histogram]) throws(ChildMetricsCursorError) {
        let url = Self.cursorURL(of: file)
        let previous: Cursor?
        do throws(MetricsLaunchFoldError) { previous = try cursor(of: file) } catch { throw ChildMetricsCursorError.unwritten(url) }
        var next = previous.flatMap { $0.launch == launch ? $0 : nil } ?? Cursor(launch: launch, histograms: [:])
        for histogram in histograms {
            next.histograms[histogram.name, default: Cursor.Counts()].add(histogram)
        }
        do {
            try JSONEncoder().encode(next).blockingWrite(to: url, options: .atomic)
        } catch {
            throw ChildMetricsCursorError.unwritten(url)
        }
    }

    /// Deletes the cursors of this role whose metrics file is gone (the dead-file fold deleted it after its upload).
    public func removeOrphanCursors() {
        guard let names = try? FileManager.checked.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return }
        for name in names where name.hasSuffix("." + Self.cursorExtension) {
            let file = directory.appending(path: String(name.dropLast(Self.cursorExtension.count)) + "bin", directoryHint: .notDirectory)
            guard files.isLaunchFile(file), !exists(file) else { continue }
            try? FileManager.checked.removeItem(at: Self.cursorURL(of: file))
        }
    }

    /// The cursor of `file`: nil when there is none, unreadable when it does not decode.
    private func cursor(of file: URL) throws(MetricsLaunchFoldError) -> Cursor? {
        guard let data = FileManager.checked.contents(atPath: Self.cursorURL(of: file).path(percentEncoded: false)) else { return nil }
        guard let cursor = try? JSONDecoder().decode(Cursor.self, from: data) else { throw MetricsLaunchFoldError.unreadable(file) }
        return cursor
    }

    /// `metrics-<role>-<pid>.folded` beside `metrics-<role>-<pid>.bin`.
    static func cursorURL(of file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension(cursorExtension)
    }

    /// The pid in `metrics-<role>-<pid>.bin`.
    static func pid(of file: URL) -> UInt32? {
        let stem = file.deletingPathExtension().lastPathComponent
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        return UInt32(stem[stem.index(after: dash)...])
    }

    /// What the app folded from one source launch of a child, per histogram name.
    struct Cursor: Codable, Sendable, Equatable {
        /// ``MetricsLaunchContents/id`` of the source launch: a cursor of an earlier process with the same pid is ignored.
        var launch: String
        var histograms: [String: Counts]

        struct Counts: Codable, Sendable, Equatable {
            var count: UInt64 = 0
            var sum: UInt64 = 0
            /// Samples per bucket index.
            var buckets: [Int: UInt64] = [:]

            mutating func add(_ histogram: MetricsDelta.Histogram) {
                count &+= histogram.count
                sum &+= histogram.sum
                for bucket in histogram.buckets { buckets[bucket.index, default: 0] &+= bucket.count }
            }
        }
    }
}

/// Why ``ChildMetricsReader/advance(_:launch:by:)`` could not record what was folded.
public enum ChildMetricsCursorError: Error, Sendable, Equatable {
    /// The cursor file could not be read or written.
    case unwritten(URL)
}

extension MetricsDelta.Histogram {
    /// These samples minus `folded`, each number at least 0 (a live file's counters only grow; a count read while
    /// a sample was half added can lag its bucket).
    func minus(_ folded: ChildMetricsReader.Cursor.Counts) -> MetricsDelta.Histogram? {
        let buckets = buckets.compactMap { bucket -> MetricsDelta.Bucket? in
            let left = bucket.count.subtractingClamped(folded.buckets[bucket.index] ?? 0)
            return left == 0 ? nil : MetricsDelta.Bucket(index: bucket.index, count: left)
        }
        let count = count.subtractingClamped(folded.count)
        guard count != 0 || !buckets.isEmpty else { return nil }
        return MetricsDelta.Histogram(name: name, layout: layout, count: count, sum: sum.subtractingClamped(folded.sum),
                                      buckets: buckets, entry: entry)
    }
}

extension UInt64 {
    fileprivate func subtractingClamped(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}

extension Metrics {
    /// Adds a child process's samples of `id` (count, sum and buckets, read from its metrics file) to this
    /// process's histogram, as Chrome's `HistogramBase::AddSamples` merges a child's delta. Nothing is added
    /// when `histogram` is another histogram, was counted in another bucket layout, `id` has expired, or no store is
    /// attached.
    ///
    /// - Returns: Whether the samples were added.
    @discardableResult
    public func record(_ id: HistogramID, folding histogram: MetricsDelta.Histogram) -> Bool {
        guard let store = foldingStore(id, histogram) else { return false }
        return store.add(id, count: histogram.count, sum: histogram.sum, buckets: histogram.buckets)
    }

    /// Whether ``record(_:folding:)`` would add `histogram` to `id` now: the same name and bucket layout, a store
    /// attached and `id` not expired in it.
    public func accepts(_ id: HistogramID, folding histogram: MetricsDelta.Histogram) -> Bool {
        foldingStore(id, histogram) != nil
    }

    /// The attached store when it has a block for `id` and `histogram` was counted in `id`'s layout.
    private func foldingStore(_ id: HistogramID, _ histogram: MetricsDelta.Histogram) -> MetricsStore? {
        guard histogram.name == id.name, histogram.layout == id.layout, let store = MetricsStore.attached(to: runtime),
              store.slots[id] != nil else { return nil }
        return store
    }
}

/// Folds the local daemon's request latency into the app's histograms at a report (task 062): maps the daemon's
/// metrics file read-only (``ChildMetricsReader``) and adds what it recorded since the last fold to the app's
/// `daemon.request.<class>` and `daemon.dispatch.queue_us`, with no socket request. The report then sends them with
/// the app's own histograms (``MetricsStore/delta()``).
///
/// One fold runs at a time; a fold asked for while one runs is counted as ``Outcome/busy`` and the next report picks
/// up its samples. ``tally`` counts every outcome, a missing file included; the app shows it in `debug.shipping_mode`'s
/// `hang_reports.daemon_metrics_fold`.
///
/// ```swift
/// let fold = DaemonMetricsFold(reader: ChildMetricsReader(role: .daemon, directory: folder), metrics: Metrics(), work: work)
/// _ = await fold.fold(pid: daemonPID)
/// ```
public actor DaemonMetricsFold {
    /// What one fold did.
    public enum Outcome: Sendable, Equatable {
        /// The file's new samples went into `histograms` of the app's histograms (`samples` in all).
        case folded(histograms: Int, samples: UInt64)
        /// No local daemon runs.
        case noDaemon
        /// The daemon runs but has no metrics file (a daemon without task 131, or one that has not mapped it yet).
        case missing
        /// The file or its cursor does not decode.
        case unreadable
        /// The app has no metrics store yet: nothing was folded, so the next fold takes the samples.
        case noStore
        /// The cursor could not be written: nothing was folded, so no sample is folded twice.
        case cursorUnwritten
        /// Another fold was running.
        case busy
        /// The files lane dropped the fold (shutdown or cancellation).
        case cancelled
    }

    /// How often each outcome happened.
    public struct Tally: Sendable, Equatable {
        /// Folds that read the file.
        public var folded = 0
        /// Daemon samples added to the app's histograms.
        public var samples: UInt64 = 0
        /// Reports with no local daemon.
        public var noDaemon = 0
        /// Reports whose daemon had no metrics file.
        public var missing = 0
        /// Reports whose daemon file or cursor did not decode.
        public var unreadable = 0
        /// Reports before the app's store was attached.
        public var noStore = 0
        /// Reports whose cursor could not be written.
        public var cursorUnwritten = 0
        /// Reports that came while a fold ran.
        public var busy = 0
        /// Folds the files lane dropped.
        public var cancelled = 0

        /// No outcome yet.
        public init() {}

        /// Each count under its snake_case name, as `debug.shipping_mode` shows them (`missing`, `no_daemon`, ...).
        public var byName: [String: UInt64] {
            ["folded": UInt64(folded), "samples": samples, "no_daemon": UInt64(noDaemon), "missing": UInt64(missing),
             "unreadable": UInt64(unreadable), "no_store": UInt64(noStore), "cursor_unwritten": UInt64(cursorUnwritten),
             "busy": UInt64(busy), "cancelled": UInt64(cancelled)]
        }

        /// Counts `outcome`.
        public mutating func count(_ outcome: Outcome) {
            switch outcome {
            case let .folded(histograms: _, samples: added):
                folded += 1
                samples &+= added
            case .noDaemon: noDaemon += 1
            case .missing: missing += 1
            case .unreadable: unreadable += 1
            case .noStore: noStore += 1
            case .cursorUnwritten: cursorUnwritten += 1
            case .busy: busy += 1
            case .cancelled: cancelled += 1
            }
        }
    }

    /// The daemon histograms the fold takes from the file, by name; the file's other histograms (locks, the journal)
    /// stay in the daemon's own section.
    static let foldedIDs: [String: HistogramID] = Dictionary(
        ([HistogramID.daemonDispatchQueue] + HistogramID.MethodClass.allCases.map(HistogramID.daemonRequest)).map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first })

    private let reader: ChildMetricsReader
    private let metrics: Metrics
    private let work: any MayBlockRunner
    private var folding = false
    /// Every outcome so far.
    public private(set) var tally = Tally()

    /// A fold of the daemon files `reader` reads into `metrics`' store, with file work on `work`'s files lane.
    public init(reader: ChildMetricsReader, metrics: Metrics, work: any MayBlockRunner) {
        self.reader = reader
        self.metrics = metrics
        self.work = work
    }

    /// Folds the daemon `pid`'s new samples (``foldNow(pid:reader:metrics:)`` on the files lane) and counts the outcome.
    @discardableResult
    public func fold(pid: Int32?) async -> Outcome {
        let outcome: Outcome
        if folding {
            outcome = .busy
        } else if let pid, pid > 0 {
            folding = true
            let reader = reader, metrics = metrics, child = UInt32(pid)
            outcome = (try? await work.runFiles(.userVisible) { Self.foldNow(pid: child, reader: reader, metrics: metrics) }) ?? .cancelled
            folding = false
        } else {
            outcome = .noDaemon
        }
        tally.count(outcome)
        return outcome
    }

    /// One fold, blocking: the file's samples since the cursor, for the daemon histograms the app's store takes
    /// (``Metrics/accepts(_:folding:)``), are written to the cursor first and then added to `metrics`' store, so a
    /// failed cursor write folds nothing, nothing folds twice, and a sample the app refuses (an id expired in the
    /// app, or counted in another layout) stays in the file for the daemon's own section.
    public static func foldNow(pid: UInt32, reader: ChildMetricsReader, metrics: Metrics) -> Outcome {
        reader.removeOrphanCursors()
        let file = reader.file(pid: pid)
        guard reader.exists(file) else { return .missing }
        guard MetricsStore.attached(to: metrics.runtime) != nil else { return .noStore }
        let contents: MetricsLaunchContents
        do throws(MetricsLaunchFoldError) { contents = try reader.read(file) } catch { return .unreadable }
        let taken = contents.delta.histograms.compactMap { histogram -> (id: HistogramID, histogram: MetricsDelta.Histogram)? in
            guard let id = foldedIDs[histogram.name], metrics.accepts(id, folding: histogram) else { return nil }
            return (id, histogram)
        }
        guard !taken.isEmpty else { return .folded(histograms: 0, samples: 0) }
        do throws(ChildMetricsCursorError) {
            try reader.advance(file, launch: contents.id, by: taken.map(\.histogram))
        } catch {
            return .cursorUnwritten
        }
        var histograms = 0
        var samples: UInt64 = 0
        for (id, histogram) in taken where metrics.record(id, folding: histogram) {
            histograms += 1
            samples &+= histogram.count
        }
        return .folded(histograms: histograms, samples: samples)
    }
}
