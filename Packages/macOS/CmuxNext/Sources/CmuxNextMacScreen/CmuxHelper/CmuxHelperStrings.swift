import CmuxNextDevices
import Foundation

/// cmux Helper's app strings (`CmuxHelper` table).
enum CmuxHelperStrings {
    static var signedOut: String {
        String(localized: "remote.signedOut", defaultValue: "Sign in to cmux to share this Mac.", table: "CmuxHelper", bundle: .localizedModule)
    }
    static var allow: String { String(localized: "remote.allow", defaultValue: "Allow", table: "CmuxHelper", bundle: .localizedModule) }

    /// Sharing another Mac of this account, confirmed on this device.
    static func confirmShareOther(device: String) -> (String, String) {
        (String(format: String(localized: "remote.confirm.shareOther.title", defaultValue: "Share %@'s screen with your devices?", table: "CmuxHelper", bundle: .localizedModule), device),
         String(format: String(localized: "remote.confirm.shareOther.body",
                               defaultValue: "%@ turns on Share This Mac if its owner allowed control from your other signed-in machines. Your devices still ask before they see or control it, and both Macs record that you allowed it here.",
                               table: "CmuxHelper", bundle: .localizedModule), device))
    }

    static func notYourDevice(_ device: String) -> String {
        String(format: String(localized: "remote.notYourDevice", defaultValue: "%@ is not another device of this account.", table: "CmuxHelper", bundle: .localizedModule), device)
    }

    static func confirmAccess(device: String, scope: DeviceScope) -> (String, String) {
        let level = switch scope {
        case .none: String(localized: "remote.scope.none", defaultValue: "No Access", table: "CmuxHelper", bundle: .localizedModule)
        case .ask: String(localized: "remote.scope.ask", defaultValue: "Ask Every Time", table: "CmuxHelper", bundle: .localizedModule)
        case .view: String(localized: "remote.scope.view", defaultValue: "View Only", table: "CmuxHelper", bundle: .localizedModule)
        case .full: String(localized: "remote.scope.full", defaultValue: "Full Control", table: "CmuxHelper", bundle: .localizedModule)
        }
        return (String(format: String(localized: "remote.confirm.access.title", defaultValue: "Give %@ access to this Mac?", table: "CmuxHelper", bundle: .localizedModule), device),
                String(format: String(localized: "remote.confirm.access.body", defaultValue: "An agent asked to set %1$@ to %2$@.", table: "CmuxHelper", bundle: .localizedModule), device, level))
    }
}
