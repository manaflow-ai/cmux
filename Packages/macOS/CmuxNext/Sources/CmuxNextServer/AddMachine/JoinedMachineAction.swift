import Foundation

/// What a joined machine's menu does (its "…" button). Each is a registered action
/// (`machine.joined.<rawValue>`, `ActionMenuContext.joinedMachine`) the App binds.
public nonisolated enum JoinedMachineAction: String, CaseIterable, Sendable {
    /// `machine doctor ID` in the Check Machine checklist.
    case check
    /// A new credential for it (the old one stops working).
    case rotate
    /// Revoke… (asks first): it leaves the team's machines.
    case revoke

    /// Whether the action can run on a machine in `state` (a revoked machine can only be checked).
    public func isAvailable(for state: JoinedMachine.State) -> Bool {
        self == .check || state != .revoked
    }
}

/// What the App shows around a joined machine's actions: Revoke's question, and why an action
/// cannot run (Labs off, a change already running).
extension JoinedMachineAction {
    /// Revoke's question: its title, its body (the heartbeat bound) and its button.
    public static func revokePrompt(_ name: String) -> (title: String, body: String, button: String) {
        (JoinedMachineStrings.revokeTitle(name), JoinedMachineStrings.revokeBody, JoinedMachineStrings.revokeButton)
    }

    /// Why a joined machine's action does nothing: its binder's `labsOn` said no (tests; the app's is always on).
    public static var labsOff: String { JoinedMachineStrings.labsOff }
    /// Why Rotate or Revoke waits: another change on the machine is still running.
    public static var busy: String { JoinedMachineStrings.busy }
}

/// Text of the joined machines' actions (Resources/AddMachine.xcstrings); the rows' own words are the
/// page's (webviews/src/pages/machines, the same table).
nonisolated enum JoinedMachineStrings {
    private static func s(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "AddMachine", bundle: .module)
    }

    /// How long a revoked machine keeps access at most: the platform's heartbeat interval. Every
    /// heartbeat and relay request checks live revocation, so it is cut off at the next one.
    static let heartbeatSeconds = 30

    /// A joined machine's action asked to run while its binder's `labsOn` says no (tests; never in the app).
    static var labsOff: String { s("machines.joined.labsOff", "Joined machines are off in Labs.") }
    static var busy: String { s("machines.joined.busy", "Wait for the last change on this machine to finish.") }

    static func revokeTitle(_ name: String) -> String { String(format: s("machines.joined.revokeTitle", "Revoke %@?"), name) }
    static var revokeBody: String {
        String(format: s("machines.joined.revokeBody", "It leaves your team's machines. Its access ends on its next heartbeat, within %lld seconds. To use it again, paste a new line on it."),
               heartbeatSeconds)
    }
    static var revokeButton: String { s("machines.joined.revokeButton", "Revoke") }
}
