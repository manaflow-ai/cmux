import CmuxNextDaemon
import CmuxNextDevices
import Foundation

/// cmux Computer Use's app strings (`CmuxHelperHost` table).
enum CmuxHelperStrings {
    static var unavailable: String {
        String(localized: "remote.unavailable", defaultValue: "cmux Computer Use is not running in this build.", table: "CmuxHelperHost", bundle: .module)
    }
    static var signedOut: String {
        String(localized: "remote.signedOut", defaultValue: "Sign in to cmux to share this Mac.", table: "CmuxHelperHost", bundle: .module)
    }
    static var statusTitle: String {
        String(localized: "remote.status.title", defaultValue: "cmux Computer Use", table: "CmuxHelperHost", bundle: .module)
    }
    static var done: String { String(localized: "remote.done", defaultValue: "Done", table: "CmuxHelperHost", bundle: .module) }
    static var allow: String { String(localized: "remote.allow", defaultValue: "Allow", table: "CmuxHelperHost", bundle: .module) }

    static func confirmShare() -> (String, String) {
        (String(localized: "remote.confirm.share.title", defaultValue: "Share This Mac?", table: "CmuxHelperHost", bundle: .module),
         String(localized: "remote.confirm.share.body",
                defaultValue: "Your devices can ask to see or control this Mac. You approve each one, and cmux Computer Use shows who is connected.",
                table: "CmuxHelperHost", bundle: .module))
    }

    /// Sharing another Mac of this account, confirmed on this device.
    static func confirmShareOther(device: String) -> (String, String) {
        (String(format: String(localized: "remote.confirm.shareOther.title", defaultValue: "Share %@'s screen with your devices?", table: "CmuxHelperHost", bundle: .module), device),
         String(format: String(localized: "remote.confirm.shareOther.body",
                               defaultValue: "%@ turns on Share This Mac if its owner allowed control from your other signed-in machines. Your devices still ask before they see or control it, and both Macs record that you allowed it here.",
                               table: "CmuxHelperHost", bundle: .module), device))
    }

    static func notYourDevice(_ device: String) -> String {
        String(format: String(localized: "remote.notYourDevice", defaultValue: "%@ is not another device of this account.", table: "CmuxHelperHost", bundle: .module), device)
    }

    static func confirmAccess(device: String, scope: DeviceScope) -> (String, String) {
        let level = switch scope {
        case .none: String(localized: "remote.scope.none", defaultValue: "No Access", table: "CmuxHelperHost", bundle: .module)
        case .ask: String(localized: "remote.scope.ask", defaultValue: "Ask Every Time", table: "CmuxHelperHost", bundle: .module)
        case .view: String(localized: "remote.scope.view", defaultValue: "View Only", table: "CmuxHelperHost", bundle: .module)
        case .full: String(localized: "remote.scope.full", defaultValue: "Full Control", table: "CmuxHelperHost", bundle: .module)
        }
        return (String(format: String(localized: "remote.confirm.access.title", defaultValue: "Give %@ access to this Mac?", table: "CmuxHelperHost", bundle: .module), device),
                String(format: String(localized: "remote.confirm.access.body", defaultValue: "An agent asked to set %1$@ to %2$@.", table: "CmuxHelperHost", bundle: .module), device, level))
    }

    /// The status dialog's lines: the host, the grants, each worker.
    static func statusLines(_ status: CmuxNextDaemon.JSONValue) -> [String] {
        let state = status["state"]?.stringValue ?? "off"
        let host = status["host"]
        let permissions = host?["permissions"]
        let granted = String(localized: "remote.status.granted", defaultValue: "Allowed", table: "CmuxHelperHost", bundle: .module)
        let missing = String(localized: "remote.status.missing", defaultValue: "Not allowed", table: "CmuxHelperHost", bundle: .module)
        let mark: (CmuxNextDaemon.JSONValue?) -> String = { $0?.boolValue == true ? granted : missing }
        var lines = [String(format: String(localized: "remote.status.host", defaultValue: "Host: %@", table: "CmuxHelperHost", bundle: .module), state)]
        if let permissions {
            lines.append(String(format: String(localized: "remote.status.accessibility", defaultValue: "Accessibility: %@", table: "CmuxHelperHost", bundle: .module),
                                mark(permissions["accessibility"])))
            lines.append(String(format: String(localized: "remote.status.screenRecording", defaultValue: "Screen Recording: %@", table: "CmuxHelperHost", bundle: .module),
                                mark(permissions["screen_recording"])))
        }
        for (key, title) in [("computer-use", String(localized: "remote.status.computerUse", defaultValue: "Computer Use: %@", table: "CmuxHelperHost", bundle: .module)),
                             ("screen-sharing", String(localized: "remote.status.screenSharing", defaultValue: "Screen Sharing: %@", table: "CmuxHelperHost", bundle: .module))] {
            if let worker = host?["workers"]?[key]?["state"]?.stringValue { lines.append(String(format: title, worker)) }
        }
        return lines
    }
}
