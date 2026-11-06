import CmuxNextDaemon
import CmuxNextDevices
import Foundation

/// cmux Remote's app strings (`CmuxRemote` table).
enum CmuxRemoteStrings {
    static var unavailable: String {
        String(localized: "remote.unavailable", defaultValue: "cmux Remote is not running in this build.", table: "CmuxRemote", bundle: .module)
    }
    static var signedOut: String {
        String(localized: "remote.signedOut", defaultValue: "Sign in to cmux to share this Mac.", table: "CmuxRemote", bundle: .module)
    }
    static var statusTitle: String {
        String(localized: "remote.status.title", defaultValue: "cmux Remote", table: "CmuxRemote", bundle: .module)
    }
    static var done: String { String(localized: "remote.done", defaultValue: "Done", table: "CmuxRemote", bundle: .module) }
    static var allow: String { String(localized: "remote.allow", defaultValue: "Allow", table: "CmuxRemote", bundle: .module) }

    static func confirmShare() -> (String, String) {
        (String(localized: "remote.confirm.share.title", defaultValue: "Share This Mac?", table: "CmuxRemote", bundle: .module),
         String(localized: "remote.confirm.share.body",
                defaultValue: "Your devices can ask to see or control this Mac. You approve each one, and cmux Remote shows who is connected.",
                table: "CmuxRemote", bundle: .module))
    }

    static func confirmAccess(device: String, scope: DeviceScope) -> (String, String) {
        let level = switch scope {
        case .none: String(localized: "remote.scope.none", defaultValue: "No Access", table: "CmuxRemote", bundle: .module)
        case .ask: String(localized: "remote.scope.ask", defaultValue: "Ask Every Time", table: "CmuxRemote", bundle: .module)
        case .view: String(localized: "remote.scope.view", defaultValue: "View Only", table: "CmuxRemote", bundle: .module)
        case .full: String(localized: "remote.scope.full", defaultValue: "Full Control", table: "CmuxRemote", bundle: .module)
        }
        return (String(format: String(localized: "remote.confirm.access.title", defaultValue: "Give %@ access to this Mac?", table: "CmuxRemote", bundle: .module), device),
                String(format: String(localized: "remote.confirm.access.body", defaultValue: "An agent asked to set %1$@ to %2$@.", table: "CmuxRemote", bundle: .module), device, level))
    }

    /// The status dialog's lines: the host, the grants, each worker.
    static func statusLines(_ status: CmuxNextDaemon.JSONValue) -> [String] {
        let state = status["state"]?.stringValue ?? "off"
        let host = status["host"]
        let permissions = host?["permissions"]
        let granted = String(localized: "remote.status.granted", defaultValue: "Allowed", table: "CmuxRemote", bundle: .module)
        let missing = String(localized: "remote.status.missing", defaultValue: "Not allowed", table: "CmuxRemote", bundle: .module)
        let mark: (CmuxNextDaemon.JSONValue?) -> String = { $0?.boolValue == true ? granted : missing }
        var lines = [String(format: String(localized: "remote.status.host", defaultValue: "Host: %@", table: "CmuxRemote", bundle: .module), state)]
        if let permissions {
            lines.append(String(format: String(localized: "remote.status.accessibility", defaultValue: "Accessibility: %@", table: "CmuxRemote", bundle: .module),
                                mark(permissions["accessibility"])))
            lines.append(String(format: String(localized: "remote.status.screenRecording", defaultValue: "Screen Recording: %@", table: "CmuxRemote", bundle: .module),
                                mark(permissions["screen_recording"])))
        }
        for (key, title) in [("computer-use", String(localized: "remote.status.computerUse", defaultValue: "Computer Use: %@", table: "CmuxRemote", bundle: .module)),
                             ("screen-sharing", String(localized: "remote.status.screenSharing", defaultValue: "Screen Sharing: %@", table: "CmuxRemote", bundle: .module))] {
            if let worker = host?["workers"]?[key]?["state"]?.stringValue { lines.append(String(format: title, worker)) }
        }
        return lines
    }
}
