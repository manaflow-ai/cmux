import CmuxNextBrowser
import CmuxNextCrashReporting
import CmuxNextSettings
import Darwin
import Foundation

/// `debug.crashes`: recent Chromium process failures (renderer per tab from
/// CEF, helper processes from the child monitor), how this launch follows
/// the previous run (restart, safe restart), the previous run's crash
/// report paths, the restart notice on screen, and the crash report
/// folder. No page content.
@MainActor
enum DebugCrashes {
    static func report(_ services: AppServices) -> JSONValue {
        let crash = services.crashRecovery
        let log = services.cache.cef.crashLog
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
            ])
        }
        launch["system_report"] = crash.previousCrashLog.map { .string($0.path) } ?? .null
        launch["report"] = crash.previousReport.map { .string($0.path) } ?? .null
        launch["notice"] = crash.noticeText.map { .string($0) } ?? .null
        return .object([
            "launch": .object(launch),
            "chromium_total": .number(Double(log.total)),
            "chromium": .array(log.records.map(record)),
            "report_dir": .string(crash.writer.directory.path),
        ])
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

    #if DEBUG
    /// `debug.crash.app`: ends this process like a crash (DEBUG builds), to
    /// verify relaunch recovery. `signal`: "segv" (default), "abort", "trap",
    /// "frozen". "frozen" is a crash that blocks: it starts the crash path
    /// (as an uncaught exception does), then traps with the task's
    /// EXC_BREAKPOINT port on a port nothing receives, so the main thread
    /// waits for an exception reply forever, as in the 2026-10-20 NIGHTLY
    /// freezes. Only the crash deadline can end it.
    /// `reporting` tags the Sentry event `deliberate_crash`, so it can be filtered out.
    static func crashApp(_ params: [String: JSONValue], _ reporting: AppCrashReporting? = nil) -> Never {
        reporting?.reporter.markDeliberateCrash("debug.crash.app")
        let signal = params["signal"]?.stringValue
        switch signal {
        case "abort": abort()
        case "trap", "frozen":
            if signal == "frozen" { freezeNextTrap() }
            fatalError("debug.crash.app")
        default:
            _ = raise(SIGSEGV)
            abort()
        }
    }

    /// Points the task's EXC_BREAKPOINT exception port at a new port no
    /// thread receives on (`frozen`).
    private static func freezeNextTrap() {
        let task = mach_task_self_
        var port = mach_port_t(0)
        guard mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &port) == KERN_SUCCESS,
              mach_port_insert_right(task, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS else { return }
        _ = task_set_exception_ports(task, exception_mask_t(EXC_MASK_BREAKPOINT), port,
                                     exception_behavior_t(EXCEPTION_DEFAULT), thread_state_flavor_t(THREAD_STATE_NONE))
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

#if DEBUG
/// The target of `debug.crash.exception`'s run-loop perform.
final class DebugExceptionRaiser: NSObject {
    static let shared = DebugExceptionRaiser()

    @objc func raiseNow() {
        NSException(name: .internalInconsistencyException, reason: "debug.crash.exception (cx-r3q)", userInfo: nil).raise()
    }
}
#endif
