import AppKit
import CmuxNextBrowser
import CmuxNextControl
import CmuxNextCrashReporting
import Foundation
import os
import CmuxNextCompat

/// Whole-app crash recovery and crash visibility (plans/cmux-next/browser-isolation.md):
/// the run marker, the restart notice, crash reports for app and Chromium
/// failures, and the `debug.crashes` report.
@MainActor
final class CrashRecoveryService {
    /// Nil when this process is not the app (tests): no marker, no
    /// handlers, a clean launch.
    let marker: AppRunMarker?
    let writer: CrashReportWriter
    /// macOS's `.ips` report of the previous run's crash, when there is one.
    private(set) var previousCrashLog: URL?
    /// Our own report of the previous run's end.
    private(set) var previousReport: URL?
    private var crashObserver: UUID?
    private weak var crashLog: BrowserCrashLog?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
    private var notice: RestartNoticePanel?
    private var noticeShown = false
    private var reportTask: Task<Void, Never>?
    /// Keeps this run's `CrashContext` in the run marker; nil without a marker.
    private(set) var contextRecorder: CrashContextRecorder?

    var recovery: LaunchRecovery { marker?.recovery ?? .clean }

    /// `marksRun` false (tests, tools that build AppServices) leaves no
    /// marker and installs no signal handlers.
    init(bundleID: String?, marksRun: Bool) {
        writer = CrashReportWriter.standard(bundleID: bundleID)
        marker = marksRun ? AppRunMarker(directory: AppRunMarker.standardDirectory(bundleID: bundleID),
                                         build: (writer.version, Bundle.main.infoDictionary?["CMUXCommit"] as? String)) : nil
        if let previous = marker?.recovery.previous {
            logger.error("previous run ended unexpectedly signal=\(previous.signal ?? 0) exception=\(previous.exception?.name ?? "none", privacy: .public) safe=\(self.recovery.isSafeRestart) held_pages=\(self.recovery.crashedPages.count)")
            reportTask = Task { [weak self, writer] in  // task-owner: stored in reportTask, cancelled with the service
                // The DiagnosticReports listing and the report write stay off the main thread.
                let found = await Task.detached(priority: .utility) {
                    CrashRecoveryService.systemCrashLog(after: previous.launched)
                }.value
                guard let self else { return }
                previousCrashLog = found
                let data = CrashReportWriter.encode(appReport(previous))
                previousReport = await Task.detached(priority: .utility) { writer.write(data, name: "app") }.value
            }
        }
    }

    /// Writes a report for each Chromium failure from now on.
    func observe(_ log: BrowserCrashLog) {
        guard crashLog == nil else { return }
        crashLog = log
        let writer = writer
        crashObserver = log.addObserver { record in writer.writeInBackground(record) }
    }

    /// Records what this run is doing on every action run (`CrashContextRecorder`), for the next
    /// launch's crash report. Does nothing without a run marker (tests).
    func recordContext<Run: Sendable>(on runs: AsyncStream<Run>, snapshot: @escaping CrashContextRecorder.Snapshot) {
        guard let marker, contextRecorder == nil else { return }
        let recorder = CrashContextRecorder(snapshot: snapshot) { [weak marker] in marker?.record(context: $0) }
        recorder.start(runs)
        recorder.record()
        contextRecorder = recorder
    }

    /// Shows "cmux restarted after a problem" once per launch, on the first
    /// window presented after a restart.
    func showRestartNotice(on window: NSWindow?) {
        guard recovery.isRestart, !noticeShown, let window else { return }
        noticeShown = true
        var text = CrashStrings.restartNotice
        if let previous = recovery.previous, let cause = CrashIssueReport.cause(of: previous) {
            text += " " + CrashStrings.cause(cause.count > 80 ? String(cause.prefix(79)) + "…" : cause)
        }
        // The report paths are found off the main thread after launch; the
        // button reads them when clicked (the same path as Help > Show
        // Crash Logs).
        let panel = RestartNoticePanel(text: text, onShowLog: { [weak self] in
            self?.showCrashLogs()
        }, onReport: { [weak self] in
            self?.reportCrash()
        })
        panel.show(on: window)
        notice = panel
    }

    /// Help > Show Crash Logs, the palette, `cmux settings show-crash-logs`
    /// and the restart notice: the newest crash log in
    /// TextEdit (`CrashLogOpener`). The folder listing runs off the main
    /// thread.
    func showCrashLogs(opener: CrashLogOpener = .system) {
        let previousSystemLog = previousCrashLog
        let previousReport = previousReport
        let directory = writer.directory
        Task.detached(priority: .userInitiated) {  // task-owner: one-shot open; nothing to cancel
            let target = CrashLogOpener.target(
                previousSystemLog: previousSystemLog, previousReport: previousReport, reportDirectory: directory,
                systemLogs: CrashRecoveryService.systemLogsFolder, executable: ProcessInfo.processInfo.processName)
            await MainActor.run { _ = opener.show(target) }
        }
    }

    /// The notice's Report button: the previous crash as a prefilled GitHub
    /// issue in the default browser. The user reads it and sends it, or not.
    /// macOS's report is read and symbolicated off the main thread.
    func reportCrash() {
        guard let previous = recovery.previous else { return }
        let writer = writer
        let found = previousCrashLog
        let logger = logger
        Task.detached(priority: .userInitiated) {  // task-owner: one-shot report; nothing to cancel
            let url = CrashRecoveryService.issueReport(previous: previous, writer: writer, systemLog: found).url
            await MainActor.run {
                guard let url else { return logger.error("crash report page has no URL") }
                NSWorkspace.shared.openInBackground(url) { opened in
                    if !opened { logger.error("crash report page did not open") }
                }
            }
        }
    }

    /// The Report button's issue: `previous` with macOS's report of it (`systemLog`, else the
    /// newest one written after its launch) and this build's commit. Reads files; call off main.
    nonisolated static func issueReport(previous: PreviousRun, writer: CrashReportWriter, systemLog: URL?,
                                        info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> CrashIssueReport {
        let log = systemLog ?? systemCrashLog(after: previous.launched)
        let system = log.flatMap { try? Data(blockingContentsOf: $0) }.flatMap(SystemCrashReport.init(data:))
        let symbolicator = StackSymbolicator()
        // The crashed build, not this one: an update may have installed since. A marker from before
        // these fields names it through macOS's report; this build's commit only when that is this build.
        let running = info["CMUXCommit"] as? String
        let version = previous.version ?? system?.version ?? writer.version
        let commit = previous.commit ?? (version == writer.version ? running : nil)
        return CrashIssueReport(previous: previous, version: version, bundleID: writer.bundleID,
                                commit: commit, system: system, systemReportName: log?.lastPathComponent,
                                executableFunction: { symbolicator.executableFunction(uuid: $0, imageOffset: $1, returnAddress: $2) })
    }

    nonisolated static var systemLogsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    }

    /// The restart notice's text while it is shown (`debug.crashes`).
    var noticeText: String? { notice?.isShown == true ? notice?.text : nil }

    /// A requested quit has begun (`AppRunMarker.markQuitting`); returns
    /// once that is on disk or its deadline passed.
    func quitBegan() async {
        await marker?.markQuitting(timeout: QuitDeadline.quitMarkLimit)
    }

    /// A normal quit.
    func applicationWillTerminate() {
        contextRecorder?.stop()
        if let crashObserver { crashLog?.removeObserver(crashObserver) }
        marker?.markCleanExit()
    }

    func appReport(_ previous: PreviousRun) -> [String: Any] {
        var object: [String: Any] = [
            "kind": "app",
            "launched": CrashReportWriter.iso(previous.launched),
            "found": CrashReportWriter.iso(Date()),
            "pid": Int(previous.pid),
            "was_restart": previous.recovery,
            "lived_past_quick_window": previous.survived,
            "bundle_id": writer.bundleID,
            "version": writer.version,
            "browser_pages_held": recovery.crashedPages.count,
        ]
        if let signal = previous.signal {
            object["signal"] = Int(signal)
            object["signal_name"] = BrowserProcessExit(reason: .crashed, code: Int(signal)).codeDescription ?? String(signal)
        }
        if let exception = previous.exception {
            object["exception_name"] = exception.name
            object["exception_reason"] = exception.reason
            object["exception_frames"] = exception.frames
        }
        if let previousCrashLog { object["system_report"] = previousCrashLog.path }
        return object
    }

    /// The newest macOS crash report of this executable written after
    /// `date` (`~/Library/Logs/DiagnosticReports/<name>-<date>.ips`).
    nonisolated static func systemCrashLog(after date: Date, name: String = ProcessInfo.processInfo.processName) -> URL? {
        let folder = systemLogsFolder
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "ips" && $0.lastPathComponent.hasPrefix(name + "-") }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .filter { $0.1 >= date }
            .max { $0.1 < $1.1 }?.0
    }
}
