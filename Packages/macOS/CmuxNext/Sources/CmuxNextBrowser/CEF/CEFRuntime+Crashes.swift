import Darwin
import Foundation

/// Renderer and helper process failures: the tab-level record from CEF and
/// the process-level record from `CEFChildProcessMonitor`.
extension CEFRuntime {
    func recordRendererExit(_ exit: BrowserProcessExit, tab: CEFTab) {
        logger.error("renderer ended reason=\(exit.reason.rawValue, privacy: .public) code=\(exit.code ?? 0) tab=\(tab.id.rawValue, privacy: .public)")
        crashLog.append(BrowserCrashRecord(processType: "renderer", reason: exit.reason, code: exit.code,
                                           tab: tab.id, source: .engine))
    }

    func startChildMonitor() {
        guard childMonitor == nil else { return }
        let monitor = CEFChildProcessMonitor { exit in
            Task { @MainActor in CEFRuntime.shared.childExited(exit) }
        }
        childMonitor = monitor
        monitor.start()
    }

    func childExited(_ exit: CEFChildProcessMonitor.Exit) {
        // Quit closes every helper; those ends are expected.
        guard state == .ready, shutdownSequence == nil,
              let reason = Self.abnormalReason(status: exit.status) else { return }
        let type = exit.isExtension ? "extension" : exit.processType
        logger.error("helper ended type=\(type, privacy: .public) sub=\(exit.subType ?? "-", privacy: .public) pid=\(exit.pid) reason=\(reason.rawValue, privacy: .public) status=\(exit.status)")
        crashLog.append(BrowserCrashRecord(processType: type, subType: exit.subType, pid: exit.pid, reason: reason,
                                           code: Int(exit.status), source: .process))
    }

    /// Nil for a normal end (exit 0, or SIGTERM, which Chromium sends to
    /// helpers it no longer needs); otherwise why the helper ended.
    nonisolated static func abnormalReason(status: Int32) -> BrowserProcessExit.Reason? {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff == 0 ? nil : .abnormal
        }
        if signal == 0x7f { return nil }  // stopped, not ended
        switch signal {
        case SIGTERM: return nil
        case SIGKILL: return .killed
        default: return .crashed
        }
    }
}
