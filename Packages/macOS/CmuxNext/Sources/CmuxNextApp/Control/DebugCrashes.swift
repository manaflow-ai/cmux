import CmuxNextBrowser
import CmuxNextSettings
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
    /// verify relaunch recovery. `signal`: "segv" (default), "abort", "trap".
    static func crashApp(_ params: [String: JSONValue]) -> Never {
        switch params["signal"]?.stringValue {
        case "abort": abort()
        case "trap": fatalError("debug.crash.app")
        default:
            _ = raise(SIGSEGV)
            abort()
        }
    }
    #endif
}
