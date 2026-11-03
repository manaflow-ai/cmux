import CmuxNextComputerUse
import CmuxNextSettings
import Foundation

/// Computer Use approval strings (`CmuxRemote` table).
enum ComputerUseApprovalStrings {
    static func title(agent: String, app: String) -> String {
        String(format: String(localized: "computerUse.approval.title", defaultValue: "Allow %1$@ to use %2$@?", table: "CmuxRemote", bundle: .module),
               agent, app)
    }

    static func asker(agent: String, workspace: String) -> String {
        workspace.isEmpty
            ? String(format: String(localized: "computerUse.approval.asker", defaultValue: "%@ wants to see and use this app.", table: "CmuxRemote", bundle: .module), agent)
            : String(format: String(localized: "computerUse.approval.askerWorkspace", defaultValue: "%1$@ in %2$@ wants to see and use this app.", table: "CmuxRemote", bundle: .module),
                     agent, workspace)
    }

    static func client(_ client: String) -> String {
        String(format: String(localized: "computerUse.approval.client", defaultValue: "Asked through %@.", table: "CmuxRemote", bundle: .module), client)
    }

    static func expires(_ time: String) -> String {
        String(format: String(localized: "computerUse.approval.expires", defaultValue: "Answer by %@.", table: "CmuxRemote", bundle: .module), time)
    }

    static var allowOnce: String {
        String(localized: "computerUse.approval.allowOnce", defaultValue: "Allow Once", table: "CmuxRemote", bundle: .module)
    }
    static var allowSession: String {
        String(localized: "computerUse.approval.allowSession", defaultValue: "Allow for This Session", table: "CmuxRemote", bundle: .module)
    }
    static func allowAlways(_ app: String) -> String {
        String(format: String(localized: "computerUse.approval.allowAlways", defaultValue: "Always Allow %@", table: "CmuxRemote", bundle: .module), app)
    }
    static var deny: String {
        String(localized: "computerUse.approval.deny", defaultValue: "Deny", table: "CmuxRemote", bundle: .module)
    }

    // MARK: Revoke and status

    static var revokeTitle: String {
        String(localized: "computerUse.revoke.title", defaultValue: "Revoke Saved App Approvals", table: "CmuxRemote", bundle: .module)
    }
    static var revokeBody: String {
        String(localized: "computerUse.revoke.body", defaultValue: "Agents will ask again before they use the apps you choose.", table: "CmuxRemote", bundle: .module)
    }
    static var revokeNone: String {
        String(localized: "computerUse.revoke.none", defaultValue: "No apps are saved. Agents ask before they use any app.", table: "CmuxRemote", bundle: .module)
    }
    static var revokeAll: String {
        String(localized: "computerUse.revoke.all", defaultValue: "Revoke All", table: "CmuxRemote", bundle: .module)
    }
    static var revokeChosen: String {
        String(localized: "computerUse.revoke.chosen", defaultValue: "Revoke", table: "CmuxRemote", bundle: .module)
    }

    static var statusTitle: String {
        String(localized: "computerUse.status.title", defaultValue: "Computer Use", table: "CmuxRemote", bundle: .module)
    }

    static func modeName(_ mode: ComputerUseMode) -> String {
        switch mode {
        case .ask: String(localized: "computerUse.mode.ask", defaultValue: "Ask Before Using Apps", table: "CmuxRemote", bundle: .module)
        case .bounded: String(localized: "computerUse.mode.bounded", defaultValue: "Approved Apps Only", table: "CmuxRemote", bundle: .module)
        case .standard: String(localized: "computerUse.mode.standard", defaultValue: "Standard", table: "CmuxRemote", bundle: .module)
        case .unrestricted: String(localized: "computerUse.mode.unrestricted", defaultValue: "Unrestricted", table: "CmuxRemote", bundle: .module)
        }
    }

    static func statusLines(mode: ComputerUseMode, phoneAlwaysAllow: Bool, saved: [String], pending: Int) -> [String] {
        let on = String(localized: "computerUse.status.on", defaultValue: "On", table: "CmuxRemote", bundle: .module)
        let off = String(localized: "computerUse.status.off", defaultValue: "Off", table: "CmuxRemote", bundle: .module)
        let none = String(localized: "computerUse.status.noApps", defaultValue: "none", table: "CmuxRemote", bundle: .module)
        return [
            String(format: String(localized: "computerUse.status.mode", defaultValue: "Mode: %@", table: "CmuxRemote", bundle: .module), modeName(mode)),
            String(format: String(localized: "computerUse.status.phoneAlways", defaultValue: "Always Allow from iPhone: %@", table: "CmuxRemote", bundle: .module),
                   phoneAlwaysAllow ? on : off),
            String(format: String(localized: "computerUse.status.saved", defaultValue: "Saved apps: %@", table: "CmuxRemote", bundle: .module),
                   saved.isEmpty ? none : saved.joined(separator: ", ")),
            String(format: String(localized: "computerUse.status.pending", defaultValue: "Waiting questions: %lld", table: "CmuxRemote", bundle: .module), pending),
        ]
    }

    static func confirmMode(_ mode: ComputerUseMode) -> (String, String) {
        (String(format: String(localized: "computerUse.confirmMode.title", defaultValue: "Change Computer Use to %@?", table: "CmuxRemote", bundle: .module), modeName(mode)),
         mode == .unrestricted
            ? String(localized: "computerUse.confirmMode.unrestricted",
                     defaultValue: "An agent asked for this. Agents could then use every app on this Mac without asking you. Use it only on a disposable machine.",
                     table: "CmuxRemote", bundle: .module)
            : String(localized: "computerUse.confirmMode.body",
                     defaultValue: "An agent asked for this. Agents would ask you less often before they use your apps.",
                     table: "CmuxRemote", bundle: .module))
    }

    static var change: String {
        String(localized: "computerUse.confirmMode.change", defaultValue: "Change", table: "CmuxRemote", bundle: .module)
    }
}
