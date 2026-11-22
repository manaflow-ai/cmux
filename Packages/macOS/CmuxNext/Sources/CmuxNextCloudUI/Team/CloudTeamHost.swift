public import CmuxNextDaemon
public import CmuxNextDesign
public import AppKit

/// One of the person's Cloud machines as this Mac has it: its id, its daemon's store, its status
/// (`CloudMachine.Status`'s raw value).
public struct CloudTeamMachine {
    public var vm: String
    public var store: DaemonStore
    public var status: String

    public init(vm: String, store: DaemonStore, status: String) {
        self.vm = vm
        self.store = store
        self.status = status
    }
}

/// What the Team feature needs from the app: one-line forwards (AppServices+CloudTeamHost.swift).
@MainActor
public protocol CloudTeamHost: AnyObject {
    /// One signed-in call to cmux Cloud (`v1/read` or `v1/ops`), `team` in `x-cmux-team`.
    func cloudTeamCall(_ path: String, _ body: [String: Any], team: String?) async throws -> [String: Any]
    var cloudTeamSignedIn: Bool { get }
    var cloudTeamID: String? { get }
    var cloudTeamUserID: String? { get }
    /// The ids of the person's Cloud machines (never a teammate's: CloudMachineShare refuses those).
    var cloudTeamMachineIDs: [String] { get }
    func cloudTeamStore(_ vm: String) -> DaemonStore?
    /// The machine's `CloudMachine.Status` raw value.
    func cloudTeamStatus(_ vm: String) -> String?
    var cloudTeamActiveMachine: String? { get }
    var cloudTeamActiveWorkspaceKey: String? { get }
    /// A workspace by its key or resource id, and its machine's id.
    func cloudTeamWorkspace(_ id: String) -> WorkspaceModel?
    func cloudTeamWorkspaceMachine(_ id: String) -> String?
    func cloudTeamRevealTab(_ id: String, intent: WindowActivation.Intent) -> Bool
    /// The window that shows the workspace (its key) once revealed, nil when none can.
    func cloudTeamWindow(workspace key: String) -> NSWindow?
    func cloudTeamShowWindow(_ window: NSWindow, intent: WindowActivation.Intent)
    /// The theme tokens of the active window, for the sidebar section's colors.
    var cloudTeamTokens: ThemeTokens { get }
}

extension CloudTeamHost {
    /// The person's Cloud machines with their stores and states.
    var cloudTeamMachines: [CloudTeamMachine] {
        cloudTeamMachineIDs.compactMap { vm in
            cloudTeamStore(vm).map { CloudTeamMachine(vm: vm, store: $0, status: cloudTeamStatus(vm) ?? "unknown") }
        }
    }

    var cloudTeamActiveWorkspace: (machine: String, workspace: String)? {
        guard let machine = cloudTeamActiveMachine, let workspace = cloudTeamActiveWorkspaceKey else { return nil }
        return (machine, workspace)
    }

    func cloudTeamRevealWorkspace(_ key: String, intent: WindowActivation.Intent) -> Bool {
        guard let window = cloudTeamWindow(workspace: key) else { return false }
        cloudTeamShowWindow(window, intent: intent)
        return true
    }
}
