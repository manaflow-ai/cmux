import CmuxHive
import Foundation

/// A single window’s live workspace and terminal ownership for one remote Mac.
@MainActor
final class HiveDeviceMirror {
    let deviceID: String
    var computerName: String = ""
    weak var tabManager: TabManager?
    var reconcileTask: Task<Void, Never>?
    var routeTask: Task<Void, Never>?
    let workspaceReadiness = HiveMirrorWorkspaceReadiness()
    var windowCloseObserver: NSObjectProtocol?
    /// Local mirror workspace id per remote workspace id.
    var workspaceIdByRemoteID: [String: UUID] = [:]
    /// Terminal streams per remote terminal id.
    var terminalsByRemoteID: [String: HiveRemoteTerminalSession] = [:]
    /// Local display-tab panel id per remote terminal id.
    var panelIdByRemoteTerminalID: [String: UUID] = [:]
    /// Remote terminal ids per remote workspace id (repaint scoping and
    /// dead-terminal pruning).
    var terminalIDsByRemoteWorkspaceID: [String: [String]] = [:]

    init(deviceID: String) {
        self.deviceID = deviceID
    }
}
