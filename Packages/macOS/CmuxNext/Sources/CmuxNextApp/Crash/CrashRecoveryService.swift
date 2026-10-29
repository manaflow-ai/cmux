import AppKit
import CmuxNextBrowser
import Foundation
import os
import CmuxNextCompatAppKit
import CmuxNextCrashReporting
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextLaunch
import CmuxNextMetrics
import CmuxNextWakeups

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
    /// The crash keys the previous run's crash path wrote (`run.crashkeys`), read off the main thread after launch.
    private(set) var previousCrashKeys: CrashKeys?
    private var crashObserver: UUID?
    private var helperExitObserver: UUID?
    /// Which Chromium helper ends go to Sentry (``helperExited(_:reporter:at:)``).
    private var helperExitLimiter = HelperExitRateLimiter()
    private weak var crashLog: BrowserCrashLog?
    /// The Chromium Host's Crashpad dumps (`debug.crashes`), once Chromium started in a build that has the host.
    private(set) var chromiumDumps: ChromiumMinidumpCollector?
    private let bundleID: String?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
    private var notice: RestartNoticePanel?
    private var noticeShown = false
    /// The files lane for the crash folders' listings and the report write.
    private let work: BackgroundWork
    /// The app's main-thread scheduler, where those reads reply.
    private let mainWork: MainWorkScheduler

    var recovery: LaunchRecovery { marker?.recovery ?? .clean }

    /// This launch's one reattach decision, from the run marker and feature `relaunchReattach`, which
    /// do not change while the app runs: the terminal frames' discard (`AppDelegate`) and the window picture's refusal
    /// (`LaunchSnapshotWindow`) both take it from here.
    func relaunchReattach(features: FeatureList) -> RelaunchReattach {
        RelaunchReattach(previousEnd: RelaunchReattach.PreviousEnd(marker?.previousExit), enabled: features.isEnabled(.relaunchReattach))
    }

    /// `runMarker` is the run marker's launch read (``AppRunMarker/startLaunchRead(directory:in:now:bootSession:)``),
    /// which `main` orders before the settings read, so it has ended when the services are made; nil (tests, tools
    /// that build AppServices) leaves no marker and installs no signal handlers. With a marker, the crash path writes
    /// `crashKeys` into the marker folder's `run.crashkeys`.
    init(bundleID: String?, runMarker: LaunchRead<AppRunMarker.Launch>?, crashKeys: CrashKeySlots? = nil, work: BackgroundWork,
         mainWork: MainWorkScheduler) {
        if let runMarker, runMarker.value == nil {
            Logger(subsystem: "com.cmuxterm.app.next", category: "crash").fault("run marker launch read had not ended: this run is not marked")
        }
        marker = runMarker?.value.map { AppRunMarker(launch: $0) }
        if marker != nil, let crashKeys { CrashReporter.attachCrashKeys(crashKeys) }
        writer = CrashReportWriter.standard(bundleID: bundleID)
        self.bundleID = bundleID
        self.work = work
        self.mainWork = mainWork
        if let previous = marker?.recovery.previous {
            logger.error("previous run ended unexpectedly signal=\(previous.signal ?? 0) exception=\(previous.exception?.name ?? "none", privacy: .public) safe=\(self.recovery.skipsBrowserPages)")
            // The DiagnosticReports listing runs on the files lane (the crash keys came with the marker's launch
            // read); nobody waits on it, so the reply is background work (Chrome's PostTaskAndReply,
            // base/task/task_runner.h).
            let launched = previous.launched, keys = marker?.previousCrashKeys
            work.run(.bestEffort, mayBlock: .files) {
                CrashRecoveryService.systemCrashLog(after: launched)
            }.reply(on: mainWork, class: .background, owner: "CrashRecovery.previousRun") { [weak self] systemLog in
                self?.previousRunRead(previous, systemLog: systemLog, crashKeys: keys)
            }
        }
    }

    /// The previous run's macOS report and crash keys are known: keeps them for the notice's buttons and writes this
    /// app's report of that run on the files lane.
    private func previousRunRead(_ previous: PreviousRun, systemLog: URL?, crashKeys keys: CrashKeys?) {
        // Numbers and catalog names only (CrashKeys), so the line needs no redaction.
        logger.error("previous run crash keys: \(keys?.tagLine ?? "none", privacy: .public)")
        (previousCrashLog, previousCrashKeys) = (systemLog, keys)
        let data = CrashReportWriter.encode(appReport(previous, crashKeys: keys))
        work.run(.bestEffort, mayBlock: .files) { [writer] in writer.write(data, name: "app") }
            .reply(on: mainWork, class: .background, owner: "CrashRecovery.previousReport") { [weak self] url in
                self?.previousReport = url
            }
    }

    /// Starts the run marker's quick-crash window on the app's deadline scheduler (``AppRunMarker/armSurvivalWindow(on:now:)``).
    func armSurvivalWindow(on deadlines: MainDeadlineScheduler) {
        marker?.armSurvivalWindow(on: deadlines)
    }

    /// Writes a report for each Chromium failure from now on, and sends each helper process's end to `reporter`
    /// (``helperExited(_:reporter:at:)``). The Chromium Host's ends have a fuller report of their own, written from
    /// its supervisor (``AppRunMarker/reportHostCrashes(of:writer:work:)``). With the Chromium Host in the build, also
    /// collects its Crashpad dumps (p01-process task 226): now, and after each failure (the host's own end too), when
    /// Crashpad has written the failed process's dump. `reporter` sends a helper's dump when crash reports are on.
    func observe(_ log: BrowserCrashLog, reporter: CrashReporter) {
        guard crashLog == nil else { return }
        crashLog = log
        let writer = writer
        let dumps = chromiumDumpCollector(reporter: reporter)
        chromiumDumps = dumps
        dumps?.scan()
        crashObserver = log.addObserver { record in
            dumps?.scan()
            guard record.processType != CrashRecoveryService.hostProcessType else { return }
            writer.writeInBackground(record)
        }
        helperExitObserver = log.addHelperExitObserver { [weak self] exit in self?.helperExited(exit, reporter: reporter) }
    }

    /// One Chromium helper's end as one Sentry event, at most one per process type an hour (``HelperExitRateLimiter``);
    /// the ends held back count into the next. The SDK's envelope write runs on the files lane.
    @discardableResult
    func helperExited(_ exit: BrowserHelperExit, reporter: CrashReporter, at now: ContinuousClock.Instant = .now) -> HelperExitEvent? {
        guard reporter.isStarted, let heldBack = helperExitLimiter.admit(exit.processType, at: now) else { return nil }
        let event = HelperExitEvent(processType: exit.processType, chromiumType: exit.chromiumType, subType: exit.subType,
                                    reason: exit.reason.rawValue, code: exit.code, codeName: exit.codeDescription,
                                    pid: exit.pid, pump: exit.pump, heldBack: heldBack)
        work.post(.bestEffort, mayBlock: .files) { reporter.reportHelperExit(event) }
        return event
    }

    /// The host's dump collector (nil without a run marker, or in a build without the host): the database in
    /// the host's data folder, the seen list beside the run marker, each report written into the crash folder.
    private func chromiumDumpCollector(reporter: CrashReporter?) -> ChromiumMinidumpCollector? {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard marker != nil, let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let rootCache = ChromiumHostConfiguration.rootCache(applicationSupport: support, bundleIdentifier: bundleID ?? "cmux")
        let database = ChromiumCrashpadDatabase(
            directory: ChromiumHostConfiguration.crashDatabase(rootCache: rootCache),
            stateFile: AppRunMarker.standardDirectory(bundleID: bundleID).appending(path: "chromium-dumps.json"))
        let send: (@Sendable (ChromiumMinidumpReport) -> Void)? = reporter.map { reporter in
            { @Sendable report in reporter.sendChromiumDump(report) }
        }
        let (writer, work) = (writer, work)
        return ChromiumMinidumpCollector(database: database, send: send, work: work, mainWork: mainWork) { report in
            let data = CrashReportWriter.encode(writer.report(for: report))
            work.post(.bestEffort, mayBlock: .files) { _ = writer.write(data, name: "chromium-dump-\(report.processType)", date: report.date) }
        }
        #else
        return nil
        #endif
    }

    /// The crash log's process type of the Chromium Host (`CEFRuntime.hostEnded`).
    nonisolated static let hostProcessType = "chromium-host"

    /// Shows "cmux restarted after a problem" once per launch, on the first
    /// window presented after a restart.
    func showRestartNotice(on window: NSWindow?) {
        guard recovery.isRestart, !noticeShown, let window else { return }
        noticeShown = true
        var text = recovery.skipsBrowserPages ? CrashStrings.restartNoticeSafe : CrashStrings.restartNotice
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
    /// thread, on the files lane; the open is the rest of the person's action (userBlocking).
    func showCrashLogs(opener: CrashLogOpener = .system) {
        let previousSystemLog = previousCrashLog
        let previousReport = previousReport
        let directory = writer.directory
        work.run(.userBlocking, mayBlock: .files) {
            CrashLogOpener.target(
                previousSystemLog: previousSystemLog, previousReport: previousReport, reportDirectory: directory,
                systemLogs: CrashRecoveryService.systemLogsFolder, executable: ProcessInfo.processInfo.processName)
        }.reply(on: mainWork, class: .userBlocking, owner: "CrashRecovery.showLogs") { target in _ = opener.show(target) }
    }

    /// The notice's Report button: the previous crash as a prefilled GitHub
    /// issue in the default browser. The user reads it and sends it, or not.
    @discardableResult
    func reportCrash() -> URL? {
        guard let previous = recovery.previous,
              let url = CrashIssueReport(previous: previous, version: writer.version, bundleID: writer.bundleID,
                                         crashKeys: previousCrashKeys).url else { return nil }
        let logger = logger
        NSWorkspace.shared.openInBackground(url) { opened in
            if !opened { logger.error("crash report page did not open") }
        }
        return url
    }

    nonisolated static var systemLogsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    }

    /// The restart notice's text while it is shown (`debug.crashes`).
    var noticeText: String? { notice?.isShown == true ? notice?.text : nil }

    /// A requested quit has begun (`AppRunMarker.markQuitting`); returns
    /// once that is on disk or its deadline passed.
    func quitBegan() async {
        await marker?.markQuitting()
    }

    /// A normal quit.
    func applicationWillTerminate() {
        for observer in [crashObserver, helperExitObserver].compactMap({ $0 }) { crashLog?.removeObserver(observer) }
        marker?.markCleanExit()
    }

    /// The previous run's app report: how it ended and, when its crash path wrote them, its crash keys
    /// (`crash_keys`: the scrubbed `crash_key.<name>` tags, ``CrashKeys/tags``).
    func appReport(_ previous: PreviousRun, crashKeys: CrashKeys? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "kind": "app",
            "launched": CrashReportWriter.iso(previous.launched),
            "found": CrashReportWriter.iso(Date()),
            "pid": Int(previous.pid),
            "was_restart": previous.recovery,
            "lived_past_quick_window": previous.survived,
            "bundle_id": writer.bundleID,
            "version": writer.version,
            "browser_pages_restored": !recovery.skipsBrowserPages,
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
        if previous.startupComplete == false, let task = previous.lastStartupTask { object["last_startup_task"] = task }
        if let tags = crashKeys?.tags, !tags.isEmpty { object["crash_keys"] = tags }
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

extension RelaunchReattach.PreviousEnd {
    /// The run marker's unclean exit (`AppRunMarker.previousExit`; nil after a quit as asked or on a first launch).
    init(_ exit: HistogramID.UncleanExit?) {
        switch exit {
        case nil: self = .quit
        case .crash?: self = .crashed
        case .systemShutdown?: self = .systemShutdown
        case .killed?, .fatalHang?: self = .killed
        }
    }
}
