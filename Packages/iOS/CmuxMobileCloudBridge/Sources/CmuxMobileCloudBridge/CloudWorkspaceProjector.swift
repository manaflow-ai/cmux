public import CmuxMobileCloud
public import CmuxMobileShellModel
import Foundation

/// Turns one Cloud machine's daemon catalog into the per-host workspace state
/// the shell store aggregates over.
///
/// Built per machine and holding only that machine's identity, so every rule
/// below is exercised without a tunnel, a daemon or a store.
public struct CloudWorkspaceProjector: Sendable {
    /// The row a machine's terminals are gathered under when the daemon
    /// reports them without a workspace.
    static let unassignedWorkspaceID = "unassigned"

    private let machineID: String
    private let displayName: String?

    /// Projects for one machine.
    /// - Parameters:
    ///   - machineID: The machine's stable id; becomes the host id.
    ///   - displayName: The machine's user-facing name.
    public init(machineID: String, displayName: String?) {
        self.machineID = machineID
        self.displayName = displayName
    }

    /// The host state for this machine's catalog.
    /// - Parameters:
    ///   - workspaces: The daemon's workspaces.
    ///   - terminals: The daemon's terminals, each optionally naming its
    ///     workspace.
    ///   - status: Liveness of the link to this machine.
    ///   - isAuthoritative: Whether the catalog came from a complete read
    ///     rather than a retained previous value.
    public func hostState(
        workspaces: [CloudWorkspaceSummary],
        terminals: [CloudTerminalSummary],
        status: MobileMacConnectionStatus,
        isAuthoritative: Bool
    ) -> MacWorkspaceState {
        var terminalsByWorkspace: [String: [CloudTerminalSummary]] = [:]
        var orphans: [CloudTerminalSummary] = []
        for terminal in terminals {
            if let workspaceID = terminal.workspaceID, !workspaceID.isEmpty {
                terminalsByWorkspace[workspaceID, default: []].append(terminal)
            } else {
                orphans.append(terminal)
            }
        }

        var rows: [MobileWorkspacePreview] = workspaces.map { workspace in
            preview(
                remoteWorkspaceID: workspace.id,
                name: workspace.preferredName,
                currentDirectory: workspace.root,
                terminals: terminalsByWorkspace[workspace.id] ?? []
            )
        }

        // A daemon that reports terminals without a workspace (an older build,
        // or a terminal made outside a workspace) would otherwise strand them:
        // the list would show a machine with no way to reach its terminals.
        // Gather them under one row named for the machine instead.
        if !orphans.isEmpty {
            rows.append(
                preview(
                    remoteWorkspaceID: Self.unassignedWorkspaceID,
                    name: displayName ?? machineID,
                    currentDirectory: nil,
                    terminals: orphans
                )
            )
        }

        return MacWorkspaceState(
            macDeviceID: CloudAddress(machineID: machineID).identifier,
            instanceTag: nil,
            displayName: displayName,
            workspaces: rows,
            groups: [],
            workspaceGroupsAreAuthoritative: false,
            status: status,
            workspaceSnapshotIsAuthoritative: isAuthoritative,
            // Workspace mutation (rename, move, close, grouping) is a Mac
            // socket vocabulary the daemon does not answer, so every action
            // stays hidden rather than failing when tapped.
            actionCapabilities: .none
        )
    }

    private func preview(
        remoteWorkspaceID: String,
        name: String,
        currentDirectory: String?,
        terminals: [CloudTerminalSummary]
    ) -> MobileWorkspacePreview {
        let hostID = CloudAddress(machineID: machineID).identifier
        return MobileWorkspacePreview(
            id: MobileWorkspacePreview.ID(
                rawValue: CloudAddress(
                    machineID: machineID,
                    component: remoteWorkspaceID
                ).identifier
            ),
            macDeviceID: hostID,
            macDisplayName: displayName,
            name: name,
            currentDirectory: currentDirectory,
            terminals: terminals.map { terminal in
                MobileTerminalPreview(
                    id: MobileTerminalPreview.ID(
                        rawValue: CloudAddress(
                            machineID: machineID,
                            component: terminal.id
                        ).identifier
                    ),
                    name: terminal.name.flatMap { $0.isEmpty ? nil : $0 } ?? terminal.id,
                    isReady: true
                )
            }
        )
    }
}
