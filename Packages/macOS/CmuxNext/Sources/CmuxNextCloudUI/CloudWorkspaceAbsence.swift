import Foundation

/// Why a window shows one of its Cloud workspaces as not connected (P-AUSTIN B7): no machine lists
/// the workspace now, and it is not gone (its machine did not leave the account). The window keeps
/// it, its sidebar row says why, and its content area says what brings it back, never a blank pane.
public nonisolated enum CloudWorkspaceAbsence: Hashable, Sendable {
    /// Signed out of cmux Cloud: signing in brings the workspace back.
    case signedOut
    /// cmux Cloud is turned off in this app (its setting, or the organization's policy).
    case cloudOff
    /// Its machine is paused: resuming the machine brings the workspace back.
    case paused
    /// Signed in (or the saved sign-in is still being restored), and the machine list or the
    /// machine itself has not loaded yet.
    case connecting

    /// What the content area's button does.
    public nonisolated enum Action: Hashable, Sendable {
        case signIn
        case resume
    }

    /// The state of a Cloud workspace that no machine lists now. `cloudOn`: cmux Cloud is turned on
    /// and can run in this app. `signedIn`, `restoring`: the account state. `machineListed`: the
    /// signed-in account's machine is in the app's machine list; `machineLive`: it runs (not paused).
    public init(cloudOn: Bool, signedIn: Bool, restoring: Bool, machineListed: Bool, machineLive: Bool) {
        self = .connecting // red stub
    }
    }

    /// The content area's button, nil for none (it comes back by itself, or the person turns cmux Cloud on).
    public var action: Action? { nil } // red stub

    /// The sidebar row's second line.
    public var rowStatus: String {
        switch self {
        case .signedOut: String(localized: "cloud.workspaceAbsence.row.signedOut", defaultValue: "Signed out of cmux Cloud", table: "Cloud", bundle: .module)
        case .cloudOff: String(localized: "cloud.workspaceAbsence.row.cloudOff", defaultValue: "cmux Cloud is off", table: "Cloud", bundle: .module)
        case .paused: String(localized: "cloud.workspaceAbsence.row.paused", defaultValue: "Machine paused", table: "Cloud", bundle: .module)
        case .connecting: String(localized: "cloud.workspaceAbsence.row.connecting", defaultValue: "Connecting…", table: "Cloud", bundle: .module)
        }
    }

    /// The content area's line under the workspace's name.
    public var message: String {
        switch self {
        case .signedOut:
            String(localized: "cloud.workspaceAbsence.message.signedOut", defaultValue: "This workspace is on a cmux Cloud machine. Sign in to cmux Cloud to open it.", table: "Cloud", bundle: .module)
        case .cloudOff:
            String(localized: "cloud.workspaceAbsence.message.cloudOff", defaultValue: "This workspace is on a cmux Cloud machine. Turn on cmux Cloud to open it.", table: "Cloud", bundle: .module)
        case .paused:
            String(localized: "cloud.workspaceAbsence.message.paused", defaultValue: "Its cmux Cloud machine is paused. Resume the machine to open this workspace.", table: "Cloud", bundle: .module)
        case .connecting:
            String(localized: "cloud.workspaceAbsence.message.connecting", defaultValue: "Connecting to its cmux Cloud machine…", table: "Cloud", bundle: .module)
        }
    }

    /// The button's title, nil without a button.
    public var actionTitle: String? {
        switch action {
        case .signIn?: String(localized: "cloud.workspaceAbsence.signIn", defaultValue: "Sign In…", table: "Cloud", bundle: .module)
        case .resume?: String(localized: "cloud.workspaceAbsence.resume", defaultValue: "Resume Machine", table: "Cloud", bundle: .module)
        case nil: nil
        }
    }

    /// The name of a kept workspace whose sidebar row was never saved (an older build's record).
    public static var untitledWorkspace: String { String(localized: "cloud.workspaceAbsence.untitled", defaultValue: "Cloud workspace", table: "Cloud", bundle: .module) }

    /// The header of a kept workspace's machine when its name was never saved.
    public static var unnamedMachine: String { String(localized: "cloud.workspaceAbsence.machine", defaultValue: "Cloud machine", table: "Cloud", bundle: .module) }
}
