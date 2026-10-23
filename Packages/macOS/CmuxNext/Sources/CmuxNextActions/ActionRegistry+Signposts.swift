import AppKit
import CmuxNextSignposts

extension ActionRegistry {
    /// Runs an action's handler inside the always-on `action.perform` interval and opens
    /// `action.commit`, which ends after the Core Animation commit of this turn: input to
    /// committed frame for every keyboard, menu, palette and CLI action, in Debug and Release
    /// (plans/cmux-next/architecture-refactor-DESIGN.md section 7). With no recorder attached it
    /// runs `run` and nothing else.
    func signposted(_ id: ActionID, _ invocation: ActionInvocation, _ run: () -> Void) {
        let signposter = Signposter.action
        guard signposter.isEnabled else { return run() }
        let message = "id=\(id.rawValue) origin=\(invocation.origin.rawValue) input_age_ms=\(Self.inputAgeMilliseconds())"
        let commit = signposter.begin(.actionCommit, message)
        signposter.interval(.actionPerform, message, run)
        CommitBoundary().after { signposter.end(.actionCommit, commit) }
    }

    /// Age of the OS input event being handled (a key or a click), or -1 outside one (a socket action).
    private static func inputAgeMilliseconds() -> String {
        guard let event = NSApp?.currentEvent else { return "-1" }
        switch event.type {
        case .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let age = (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1_000
            return String(format: "%.2f", age)
        default:
            return "-1"
        }
    }
}
