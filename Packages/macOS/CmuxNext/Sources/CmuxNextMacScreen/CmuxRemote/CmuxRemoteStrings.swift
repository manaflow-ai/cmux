import CmuxNextDaemon
import CmuxNextDevices
import Foundation

/// cmux Remote's app strings (`CmuxRemote` table).
enum CmuxRemoteStrings {
    static var unavailable: String {
        String(localized: "remote.unavailable", defaultValue: "cmux Remote is not running in this build.", table: "CmuxRemote", bundle: .localizedModule)
    }
    static var signedOut: String {
        String(localized: "remote.signedOut", defaultValue: "Sign in to cmux to share this Mac.", table: "CmuxRemote", bundle: .localizedModule)
    }
    static var statusTitle: String {
        String(localized: "remote.status.title", defaultValue: "cmux Remote", table: "CmuxRemote", bundle: .localizedModule)
    }
    static var done: String { String(localized: "remote.done", defaultValue: "Done", table: "CmuxRemote", bundle: .localizedModule) }
    static var allow: String { String(localized: "remote.allow", defaultValue: "Allow", table: "CmuxRemote", bundle: .localizedModule) }

    static func confirmShare() -> (String, String) {
        (String(localized: "remote.confirm.share.title", defaultValue: "Share This Mac?", table: "CmuxRemote", bundle: .localizedModule),
         String(localized: "remote.confirm.share.bodyOwn",
                defaultValue: "Your devices on this account can see or control this Mac. cmux Remote shows who is connected.",
                table: "CmuxRemote", bundle: .localizedModule))
    }

    /// Sharing another Mac of this account, confirmed on this device.
    static func confirmShareOther(device: String) -> (String, String) {
        (String(format: String(localized: "remote.confirm.shareOther.title", defaultValue: "Share %@'s screen with your devices?", table: "CmuxRemote", bundle: .localizedModule), device),
         String(format: String(localized: "remote.confirm.shareOther.body",
                               defaultValue: "%@ turns on Share This Mac if its owner allowed control from your other signed-in machines. Your devices still ask before they see or control it, and both Macs record that you allowed it here.",
                               table: "CmuxRemote", bundle: .localizedModule), device))
    }

    static func notYourDevice(_ device: String) -> String {
        String(format: String(localized: "remote.notYourDevice", defaultValue: "%@ is not another device of this account.", table: "CmuxRemote", bundle: .localizedModule), device)
    }

    static func confirmAccess(device: String, scope: DeviceScope) -> (String, String) {
        let level = switch scope {
        case .none: String(localized: "remote.scope.none", defaultValue: "No Access", table: "CmuxRemote", bundle: .localizedModule)
        case .ask: String(localized: "remote.scope.ask", defaultValue: "Ask Every Time", table: "CmuxRemote", bundle: .localizedModule)
        case .view: String(localized: "remote.scope.view", defaultValue: "View Only", table: "CmuxRemote", bundle: .localizedModule)
        case .full: String(localized: "remote.scope.full", defaultValue: "Full Control", table: "CmuxRemote", bundle: .localizedModule)
        }
        return (String(format: String(localized: "remote.confirm.access.title", defaultValue: "Give %@ access to this Mac?", table: "CmuxRemote", bundle: .localizedModule), device),
                String(format: String(localized: "remote.confirm.access.body", defaultValue: "An agent asked to set %1$@ to %2$@.", table: "CmuxRemote", bundle: .localizedModule), device, level))
    }

    /// The status dialog's lines: the host, the grants, each worker (Rust picks them: remote.statusLines).
    static func statusLines(_ status: CmuxNextDaemon.JSONValue) -> [String] {
        let granted = String(localized: "remote.status.granted", defaultValue: "Allowed", table: "CmuxRemote", bundle: .localizedModule)
        let missing = String(localized: "remote.status.missing", defaultValue: "Not allowed", table: "CmuxRemote", bundle: .localizedModule)
        let rows = RdUI.call("remote.statusLines", encoding: ["status": status]) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let format = (row["key"] as? String).flatMap(statusFormat) else { return nil }
            return String(format: format, (row["granted"] as? Bool).map { $0 ? granted : missing } ?? row["value"] as? String ?? "")
        }
    }

    /// A status line's localized format, by Rust's key.
    private static func statusFormat(_ key: String) -> String? {
        switch key {
        case "remote.status.host": String(localized: "remote.status.host", defaultValue: "Host: %@", table: "CmuxRemote", bundle: .localizedModule)
        case "remote.status.accessibility":
            String(localized: "remote.status.accessibility", defaultValue: "Accessibility: %@", table: "CmuxRemote", bundle: .localizedModule)
        case "remote.status.screenRecording":
            String(localized: "remote.status.screenRecording", defaultValue: "Screen Recording: %@", table: "CmuxRemote", bundle: .localizedModule)
        case "remote.status.computerUse":
            String(localized: "remote.status.computerUse", defaultValue: "Computer Use: %@", table: "CmuxRemote", bundle: .localizedModule)
        case "remote.status.screenSharing":
            String(localized: "remote.status.screenSharing", defaultValue: "Screen Sharing: %@", table: "CmuxRemote", bundle: .localizedModule)
        default: nil
        }
    }
}
