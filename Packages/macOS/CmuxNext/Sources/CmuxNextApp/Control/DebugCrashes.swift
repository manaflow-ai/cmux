import CmuxNextBrowser
import CmuxNextCrashReporting
import CmuxNextSettings
import Foundation

/// `debug.crashes`: recent Chromium process failures (renderer per tab from
/// CEF, helper processes from the child monitor), the Chromium Host's ends
/// in host mode (`chromium_host`: signal or exit code, CEF version, fork API
/// and its log's last lines), the Chromium Host's and its
/// helpers' Crashpad dumps with their symbolicated stacks (`chromium_dumps`),
/// how this launch follows the previous run (restart, safe
/// restart), the previous run's crash report paths, the restart notice on
/// screen, and the crash report folder. No page content.
@MainActor
enum DebugCrashes {
    static func report(_ services: AppServices) -> JSONValue {
        report(crash: services.crashRecovery, chromium: services.cache.cef.crashLog,
               hostSupervisor: services.chromiumRuntime.source.hostSupervisor)
    }

    /// The report of `crash` (this launch and the crash report folder), `log` (Chromium's process failures) and, in
    /// host mode, `hostSupervisor`'s records of the Chromium Host's ends.
    static func report(crash: CrashRecoveryService, chromium log: BrowserCrashLog,
                       hostSupervisor: (any ChromiumHostSupervising)?) -> JSONValue {
        var launch: [String: JSONValue] = [
            "recovery": .string(recoveryName(crash.recovery)),
            "skips_browser_pages": .bool(crash.recovery.skipsBrowserPages),
        ]
        if let previous = crash.recovery.previous {
            launch["previous"] = .object([
                "pid": .number(Double(previous.pid)),
                "launched": .string(CrashReportWriter.iso(previous.launched)),
                "was_restart": .bool(previous.recovery),
                "survived": .bool(previous.survived),
                "signal": previous.signal.map { .number(Double($0)) } ?? .null,
                "startup_complete": previous.startupComplete.map { .bool($0) } ?? .null,
                "last_startup_task": previous.lastStartupTask.map { .string($0) } ?? .null,
            ])
        }
        // The crash-streak safe launch: a reason means this launch read no launch cache.
        if let safeMode = crash.marker?.safeMode {
            launch["safe_mode"] = .object([
                "incomplete_launches": .number(Double(safeMode.incompleteLaunches)),
                "reason": safeMode.reason.map { .string($0.rawValue) } ?? .null,
            ])
        }
        launch["system_report"] = crash.previousCrashLog.map { .string($0.path) } ?? .null
        launch["report"] = crash.previousReport.map { .string($0.path) } ?? .null
        launch["notice"] = crash.noticeText.map { .string($0) } ?? .null
        var object: [String: JSONValue] = [
            "launch": .object(launch),
            "chromium_total": .number(Double(log.total)),
            "chromium": .array(log.records.map(record)),
            "chromium_dumps_total": .number(Double(crash.chromiumDumps?.total ?? 0)),
            "chromium_dumps": .array(crash.chromiumDumps?.reports.compactMap { JSONValue(foundation: $0.jsonObject) } ?? []),
            "report_dir": .string(crash.writer.directory.path),
        ]
        #if DEBUG || CMUX_BENCH_HOOKS
        if let supervisor = hostSupervisor as? ChromiumHostSupervisor {
            object["chromium_host_total"] = .number(Double(supervisor.crashesTotal))
            // The fields of each end's crash report (CrashReportWriter), one source for both.
            object["chromium_host"] = .array(supervisor.crashes.map { JSONValue(foundation: crash.writer.report(for: $0)) ?? .null })
        }
        #endif
        return .object(object)
    }

    private static func recoveryName(_ recovery: LaunchRecovery) -> String {
        switch recovery {
        case .clean: "clean"
        case .restarted: "restarted"
        case .restartedSafely: "restartedSafely"
        }
    }

    private static func record(_ record: BrowserCrashRecord) -> JSONValue {
        var object: [String: JSONValue] = [
            "date": .string(CrashReportWriter.iso(record.date)),
            "process_type": .string(record.processType),
            "reason": .string(record.reason.rawValue),
            "source": .string(record.source.rawValue),
        ]
        if let subType = record.subType { object["sub_type"] = .string(subType) }
        if let pid = record.pid { object["pid"] = .number(Double(pid)) }
        if let code = record.code { object["code"] = .number(Double(code)) }
        if let text = record.codeDescription { object["code_text"] = .string(text) }
        if let tab = record.tab { object["tab"] = .string(tab.rawValue) }
        return .object(object)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.crash.app`: ends this process like a crash (DEBUG builds), to
    /// verify relaunch recovery. `signal`: "segv" (default), "abort", "trap",
    /// "frozen". "frozen" is a crash that blocks: it starts the crash path
    /// (as an uncaught exception does), then traps with the task's
    /// EXC_BREAKPOINT port on a port nothing receives, so the main thread
    /// waits for an exception reply forever, as in the 2026-10-20 NIGHTLY
    /// freezes. Only the crash deadline can end it. "suspended" starts the
    /// crash path, suspends the deadline thread (as Sentry's report writer
    /// suspends every thread) and blocks the main thread: only the
    /// out-of-process ``CrashWatcher`` can end it (#22844).
    /// `reporting` tags the Sentry event `deliberate_crash`, so it can be filtered out.
    static func crashApp(_ params: [String: JSONValue], _ reporting: AppCrashReporting? = nil) -> Never {
        reporting?.reporter.markDeliberateCrash("debug.crash.app")
        switch params["signal"]?.stringValue {
        case "abort": abort()
        case "suspended": CrashReporter.blockWithDeadlineSuspended()
        case let signal? where signal == "trap" || signal == "frozen":
            if signal == "frozen" { reporting?.reporter.freezeNextTrap() }
            fatalError("debug.crash.app")
        default:
            _ = raise(SIGSEGV)
            abort()
        }
    }

    /// `debug.crash.exception`: raises an NSException from a run-loop
    /// callback AppKit dispatches (where AppKit catches and logs exceptions
    /// unless NSApplicationCrashOnExceptions is on, cx-r3q). A DEV build
    /// then crashes at this throw, and the report names
    /// `DebugExceptionRaiser.raiseNow`.
    static func raiseException(_ reporting: AppCrashReporting? = nil) -> JSONValue {
        reporting?.reporter.markDeliberateCrash("debug.crash.exception")
        DebugExceptionRaiser.shared.perform(#selector(DebugExceptionRaiser.raiseNow), with: nil, afterDelay: 0)
        return .object(["scheduled": .bool(true),
                        "crash_on_exceptions": .bool(UserDefaults.standard.bool(forKey: CrashOnExceptions.key)),
                        "crash_reporting": .bool(reporting?.reporter.isStarted ?? false)])
    }
    #endif
}

#if DEBUG || CMUX_BENCH_HOOKS
/// The target of `debug.crash.exception`'s run-loop perform.
final class DebugExceptionRaiser: NSObject {
    static let shared = DebugExceptionRaiser()

    @objc func raiseNow() {
        NSException(name: .internalInconsistencyException, reason: "debug.crash.exception (cx-r3q)", userInfo: nil).raise()
    }
}
#endif
