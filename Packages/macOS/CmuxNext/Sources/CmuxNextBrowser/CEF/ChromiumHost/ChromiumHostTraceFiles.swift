#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextMetrics
import CmuxNextTrace
import CmuxNextWakeups
import Foundation

/// Where a Chromium host writes its black box, crash keys, recording ring and metrics file
/// (plans/cmux-next/chrome-parity/p09-observability.md, task 104), and the host arguments that say so
/// (`kTraceDirSwitch` and `kMetricsDirSwitch` in `ChromiumHost/src/chromium_host_wire.h`). The host names
/// each file as CmuxNextTrace and CmuxNextMetrics name a process of role `chromium_host`, so the app reads
/// them as it reads its other children's (``TraceRingFile``, ``CrashKeyPage``, `ChildMetricsReader`).
public nonisolated struct ChromiumHostTraceFiles: Sendable, Equatable {
    /// The app's black-box folder (`TraceBlackBoxFileSteps.appDirectory`).
    public var traceDirectory: String
    /// The app's metrics folder (`HangReportFieldSources.appMetricsDirectory`); nil: the host writes no metrics file.
    public var metricsDirectory: String?

    public init(traceDirectory: String, metricsDirectory: String? = nil) {
        self.traceDirectory = traceDirectory
        self.metricsDirectory = metricsDirectory
    }

    /// The folders of the app with bundle id `bundleID`, beside its own black box and metrics files:
    /// `~/Library/Logs/<bundle id>/trace` and `.../metrics` (`HangReportFieldSources.appMetricsDirectory`).
    public static func app(bundleID: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ChromiumHostTraceFiles {
        let trace = TraceBlackBoxFileSteps.appDirectory(bundleID: bundleID, home: home)
        return ChromiumHostTraceFiles(traceDirectory: trace.path,
                                      metricsDirectory: trace.deletingLastPathComponent().appending(path: "metrics").path)
    }

    /// The host arguments: `--trace-dir=<folder>`, and `--metrics-dir=<folder>` with a metrics folder.
    var arguments: [String] {
        ["--trace-dir=\(traceDirectory)"] + (metricsDirectory.map { ["--metrics-dir=\($0)"] } ?? [])
    }

    /// The folders `arguments` (a host's launch arguments) name; nil without `--trace-dir`.
    init?(arguments: [String]) {
        func value(_ name: String) -> String? {
            arguments.last { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        guard let trace = value("trace-dir") else { return nil }
        self.init(traceDirectory: trace, metricsDirectory: value("metrics-dir"))
    }

    /// The black box of the host with `pid`.
    func blackBoxPath(pid: Int32) -> String {
        traceDirectory + "/" + TraceRingFile.fileName(role: .chromiumHost, pid: UInt32(bitPattern: pid))
    }

    /// The crash-key page of the host with `pid`.
    func crashKeysPath(pid: Int32) -> String {
        traceDirectory + "/" + CrashKeyPage.fileName(role: .chromiumHost, pid: UInt32(bitPattern: pid))
    }

    /// The files of the host with `pid` that only it writes and nothing reads once it ended: its recording ring
    /// (`chromium-host-<pid>.recording.cmxtrace`) and its metrics file (``MetricsStore/fileName(role:pid:)``).
    func liveOnlyPaths(pid: Int32) -> [String] {
        let process = UInt32(bitPattern: pid)
        let recording = traceDirectory + "/\(TraceRing.Role.chromiumHost.fileStem)-\(process).recording.cmxtrace"
        return [recording] + (metricsDirectory.map { [$0 + "/" + MetricsStore.fileName(role: .chromiumHost, pid: process)] } ?? [])
    }
}

nonisolated extension ChromiumHostConfiguration {
    /// The trace folders this configuration's host writes to (its `--trace-dir` and `--metrics-dir`), or nil.
    public var traceFiles: ChromiumHostTraceFiles? {
        ChromiumHostTraceFiles(arguments: arguments)
    }
}

nonisolated extension ChromiumHostFrame {
    /// The flow id of this input frame as app `appPID` sends it (`InputFlowOf` in
    /// `ChromiumHost/src/chromium_host_wire.h`, the same bits): the app's flow-out when it writes the frame
    /// and the host's flow-in when it dispatches it name one flow with nothing on the wire, as the daemon's
    /// request flows come from the peer pid and the request id (task 103). Nil for a frame with no event time,
    /// and for every kind but a pointer's (mouse, wheel): a key's timing is the person's typing, which the
    /// keystroke gate keeps out of every trace (task 128).
    func inputFlow(appPID: UInt32) -> UInt64? {
        guard t0 != 0, let kind, kind == .mouse || kind == .wheel else { return nil }
        return Self.inputFlow(appPID: appPID, eventTime: t0)
    }

    /// `InputFlowOf`: a splitmix64 mix of the event time and the app's pid, bit 62 set and bit 63 clear (the
    /// app's task flows set bit 63).
    static func inputFlow(appPID: UInt32, eventTime: UInt64) -> UInt64 {
        var x = eventTime ^ (UInt64(appPID) << 40) ^ 0x9e37_79b9_7f4a_7c15
        x = (x ^ (x >> 30)) &* 0xbf58_476d_1ce4_e5b9
        x = (x ^ (x >> 27)) &* 0x94d0_49bb_1331_11eb
        x ^= x >> 31
        return (x & ~(UInt64(3) << 62)) | (UInt64(1) << 62)
    }
}
#endif
