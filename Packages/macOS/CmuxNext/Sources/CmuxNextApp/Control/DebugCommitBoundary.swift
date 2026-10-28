import CmuxNextSettings
import CmuxNextSignposts
import Foundation

/// `debug.commit_boundary`: the running app's main run-loop display, layout and commit observers
/// against ``CommitBoundary/order`` (``CommitBoundaryAudit``). `ok` is false when Core Animation's
/// commit observer is missing or any of them runs after the boundary at before-waiting or exit,
/// which would end every `action.commit` before that observer's work. Run it on each supported
/// macOS major (14, 15, 26, 27) before quoting `action.commit` numbers from that major.
struct DebugCommitBoundary {
    func report() -> JSONValue {
        let audit = CommitBoundaryAudit.mainRunLoop()
        return .object([
            "macos": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "boundary_order": .number(Double(CommitBoundary.order)),
            "ok": .bool(!audit.coreAnimation.isEmpty && audit.late.isEmpty),
            "observers": .array(audit.observers.map(row)),
            "late": .array(audit.late.map(row)),
        ])
    }

    private func row(_ observer: CommitBoundaryObserver) -> JSONValue {
        .object([
            "order": .number(Double(observer.order)),
            "callout": .string(observer.callout),
            "activities": observer.activities.map { JSONValue.string("0x" + String($0, radix: 16)) } ?? .null,
            "dump": .string(observer.description),
        ])
    }
}
