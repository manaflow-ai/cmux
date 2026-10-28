public import CmuxNextCompat
public import CmuxNextTrace
public import Foundation
import Darwin
import Sentry

/// Keeps the run's fatal-hang record (``FatalHangRecord``) on disk while a main-thread hang lasts,
/// from the main-thread watchdog's thread: written at the hang threshold (2 s) with the
/// stack, rewritten at each checkpoint with the time so far, removed when the main thread answers again. A run
/// that the person or the system ends while it hangs (Force Quit, SIGKILL) leaves the file, and the next launch
/// reports it (``takePrevious(in:run:currentPID:)``). The crash-key page's `hang_in_progress` slots (start, frame
/// count, frames and images, `CrashKeyPage.beginHang`) follow the file, so a crash during the hang carries it too.
///
/// Every write is synchronous on the calling thread, a few KiB to a temporary file and a rename, with no fsync:
/// the kernel's file cache outlives the process (a SIGKILL), and only a power loss can lose the record, which
/// the next launch then counts as a system shutdown anyway. Chrome's HangWatcher likewise writes its hang dump
/// from its own thread while the hung thread is still stuck (base/threading/hang_watcher.cc).
///
/// ```swift
/// let recorder = FatalHangRecorder(directory: markerFolder, release: policy.release, dist: policy.dist)
/// recorder.began(startUptimeNanos: start, elapsedNanos: elapsed, addresses: stack, phase: nil, attribution: nil)
/// recorder.ended() // the main thread answered: the file is gone
/// ```
public final class FatalHangRecorder: Sendable {
    /// Where this process's record is written (``fileName(pid:)`` in the folder).
    public let file: URL
    private let release: String
    private let dist: String
    private let runtime: TraceRuntime
    private let pid: Int32
    /// The record on disk, nil while none is.
    ///
    /// Lock carve-out: only the watchdog thread takes it, once per hang episode event, never contended; the file
    /// work runs after it is released.
    private let current = Mutex<FatalHangRecord?>(nil)

    /// A recorder for this process.
    ///
    /// - Parameters:
    ///   - directory: The folder of the records (the run marker's).
    ///   - release: This build's Sentry release (``CrashReportingPolicy/release``).
    ///   - dist: This build's Sentry dist (``CrashReportingPolicy/dist``).
    ///   - runtime: The trace runtime whose crash-key page names the hang in progress.
    ///   - pid: The process whose record this is; this one by default.
    public init(directory: URL, release: String, dist: String, runtime: TraceRuntime = .shared, pid: Int32? = nil) {
        let pid = pid ?? getpid()
        file = directory.appending(path: Self.fileName(pid: pid))
        self.release = release
        self.dist = dist
        self.runtime = runtime
        self.pid = pid
    }

    /// The record file of process `pid`.
    public static func fileName(pid: Int32) -> String {
        "hang-\(pid).json"
    }

    /// A hang reached the threshold: writes its record (`addresses` innermost first, looked up in this process).
    ///
    /// - Parameters:
    ///   - startUptimeNanos: When the stall began (`CLOCK_UPTIME_RAW` nanoseconds).
    ///   - elapsedNanos: How long it has lasted.
    ///   - addresses: The main thread's return addresses, sampled while it was still stuck.
    ///   - phase: The main thread's phase (`cef_pump`), or nil.
    ///   - attribution: The scheduled task the sample caught, or nil.
    ///   - now: The wall clock now (the record's start is `now` minus `elapsedNanos`).
    public func began(startUptimeNanos: UInt64, elapsedNanos: UInt64, addresses: [UInt], phase: String?,
                      attribution: MainThreadHangEvent.Attribution?, now: Date = Date()) {
        let record = FatalHangRecord(pid: pid, startedAt: now.addingTimeInterval(-Double(elapsedNanos) / 1_000_000_000),
                                     startUptimeNanos: startUptimeNanos, elapsedNanos: elapsedNanos, addresses: addresses,
                                     phase: phase, attribution: attribution, release: release, dist: dist)
        current.withLock { $0 = record }
        // The images and frames first, then the count and the start (CrashKeyPage.beginHang's order).
        runtime.crashKeys?.beginHang(startNanos: startUptimeNanos, frames: record.crashKeyFrames,
                                     imageUUIDWords: record.crashKeyImageUUIDWords)
        write(record)
    }

    /// The hang is still running at a checkpoint: rewrites the record with `elapsedNanos`. Nothing without a record.
    public func progressed(elapsedNanos: UInt64) {
        let record = current.withLock { record -> FatalHangRecord? in
            guard var updated = record else { return nil }
            updated.elapsedNanos = max(updated.elapsedNanos, elapsedNanos)
            record = updated
            return updated
        }
        if let record { write(record) }
    }

    /// The main thread answered again: removes the record. Nothing without one.
    public func ended() {
        let had = current.withLock { record -> Bool in
            defer { record = nil }
            return record != nil
        }
        guard had else { return }
        runtime.crashKeys?.endHang() // a zero start says no hang; the next beginHang overwrites every frame and image
        // SAFETY: blockingUnlink reads the NUL-terminated copy of the path Swift makes for the call.
        _ = unsafe blockingUnlink(file.path)
    }

    /// Whether a record is on disk now (tests).
    var hasRecord: Bool { current.withLock { $0 != nil } }

    /// Writes `record` to a temporary file next to ``file`` and renames it over ``file``, so a reader never sees half
    /// a record. No fsync (see the type's comment). A failed write leaves the previous record.
    private func write(_ record: FatalHangRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        let temporary = file.deletingLastPathComponent().appending(path: ".\(file.lastPathComponent).tmp")
        do { try data.blockingWrite(to: temporary) } catch { return }
        // SAFETY: blockingRename and blockingUnlink read the NUL-terminated copies of the paths Swift makes for each call.
        if unsafe blockingRename(temporary.path, file.path) != 0 { _ = unsafe blockingUnlink(temporary.path) }
    }

    /// At launch: the record the previous run left in `directory`. `run` is that run's pid and launch time when it
    /// ended without being asked to and without a crash report of its own (the caller's run marker decides), else nil.
    /// Every record of another process is removed (a run that crashed or quit while it hung, an older run), so each
    /// is reported at most once; the file of `currentPID` (this process by default) stays. Blocking file work:
    /// BackgroundWork `.files`.
    public static func takePrevious(in directory: URL, run: (pid: Int32, launched: Date)?,
                                    currentPID: Int32? = nil) -> FatalHangRecord? {
        let names = (try? FileManager.checked.contentsOfDirectory(atPath: directory.path)) ?? []
        let own = fileName(pid: currentPID ?? getpid()), previous = run.map { fileName(pid: $0.pid) }
        var found: FatalHangRecord?
        for name in names where name != own && name != ".\(own).tmp" {
            let url = directory.appending(path: name)
            if name == previous, let run {
                found = FatalHangRecord.take(at: url).flatMap { $0.belongs(toRunOf: run.pid, launchedAt: run.launched) ? $0 : nil }
            } else if (name.hasPrefix("hang-") && name.hasSuffix(".json")) || (name.hasPrefix(".hang-") && name.hasSuffix(".json.tmp")) {
                // SAFETY: blockingUnlink reads the NUL-terminated copy of the path Swift makes for the call.
                _ = unsafe blockingUnlink(url.path)
            }
        }
        return found
    }
}

extension CrashReporter {
    /// The next launch's half of the fatal-hang report: on `work`'s files lane, takes the
    /// previous run's record (``FatalHangRecorder/takePrevious(in:run:currentPID:)``) and sends it as one "fatal app
    /// hang" event with that run's black box (``reportFatalHang(_:blackbox:capture:)``). A clean quit or a crash
    /// (`run` nil), or the kill switch off (`enabled` false), sends nothing and only clears old records, so a record
    /// a run left while the switch was on never goes out later. Nothing waits for it.
    ///
    /// - Parameters:
    ///   - directory: The records' folder (the run marker's).
    ///   - run: The previous run's pid and launch time when no crash report covers its end; else nil.
    ///   - enabled: Whether the `fatalHangReports` kill switch is on.
    ///   - traceDirectory: The app's black-box folder.
    ///   - hangReportsOptIn: Whether this Mac said yes to hang reports: only then does `blackbox.txt` go with the event.
    ///   - work: The app's blocking-work lanes.
    public func reportPreviousFatalHang(in directory: URL, run: (pid: Int32, launched: Date)?, enabled: Bool,
                                        traceDirectory: URL, hangReportsOptIn: Bool, work: any MayBlockRunner) {
        reportPreviousFatalHang(in: directory, run: run, enabled: enabled, traceDirectory: traceDirectory,
                                hangReportsOptIn: hangReportsOptIn, work: work, consented: { [self] in isStarted },
                                capture: Self.sentryCapture)
    }

    /// ``reportPreviousFatalHang(in:run:enabled:traceDirectory:hangReportsOptIn:work:)`` with its consent and capture
    /// seams (tests pass their own).
    func reportPreviousFatalHang(in directory: URL, run: (pid: Int32, launched: Date)?, enabled: Bool, traceDirectory: URL,
                                 hangReportsOptIn: Bool, work: any MayBlockRunner, currentPID: Int32? = nil,
                                 consented: @escaping @Sendable () -> Bool, capture: @escaping ScopedCapture) {
        let reported = enabled ? run : nil
        work.postFiles(.bestEffort, shutdown: .skipOnShutdown) {
            guard let record = FatalHangRecorder.takePrevious(in: directory, run: reported, currentPID: currentPID),
                  consented() else { return }
            let records = record.blackBoxRecords(traceDirectory: traceDirectory)
            Self.sendFatalHang(record, blackbox: Self.blackboxAttachment(records, hangReportsOptIn: hangReportsOptIn), capture: capture)
        }
    }
}
