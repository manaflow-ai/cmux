public import CmuxMobileCloud
public import CmuxMobileShellModel
import Foundation

/// Turns one Cloud machine's daemon catalog into the per-host workspace state
/// the shell store aggregates over.
///
/// A pure function of its inputs, so every rule below is testable without a
/// tunnel, a daemon or a store.
public enum CloudWorkspaceProjection: Sendable {
    /// Builds the host state for one machine.
    ///
    /// - Parameters:
    ///   - machineID: The Cloud machine's stable id; becomes the host id.
    ///   - displayName: The machine's user-facing name.
    ///   - workspaces: The daemon's workspaces.
    ///   - terminals: The daemon's terminals, each optionally naming its
    ///     workspace.
    ///   - status: Liveness of the link to this machine.
    ///   - isAuthoritative: Whether `workspaces` and `terminals` came from a
    ///     complete catalog read rather than a retained previous value.
    public static func hostState(
        machineID: String,
        displayName: String?,
        workspaces: [CloudWorkspaceSummary],
        terminals: [CloudTerminalSummary],
        status: MobileMacConnectionStatus,
        isAuthoritative: Bool
    ) -> MacWorkspaceState {
        let hostID = CloudSurfaceIdentity.hostID(machineID: machineID)
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
                machineID: machineID,
                hostID: hostID,
                displayName: displayName,
                remoteWorkspaceID: workspace.id,
                name: workspace.preferredName,
                currentDirectory: workspace.root,
                terminals: terminalsByWorkspace[workspace.id] ?? []
            )
        }

        // A daemon that reports terminals without a workspace (an older build,
        // or a terminal created outside a workspace) would otherwise strand
        // them: the catalog would list a machine with no way to reach its
        // terminals. Group them under one row named for the machine instead.
        if !orphans.isEmpty {
            rows.append(
                preview(
                    machineID: machineID,
                    hostID: hostID,
                    displayName: displayName,
                    remoteWorkspaceID: unassignedWorkspaceID,
                    name: displayName ?? machineID,
                    currentDirectory: nil,
                    terminals: orphans
                )
            )
        }

        return MacWorkspaceState(
            macDeviceID: hostID,
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

    /// The row id a machine's orphaned terminals are gathered under.
    static let unassignedWorkspaceID = "unassigned"

    private static func preview(
        machineID: String,
        hostID: String,
        displayName: String?,
        remoteWorkspaceID: String,
        name: String,
        currentDirectory: String?,
        terminals: [CloudTerminalSummary]
    ) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: MobileWorkspacePreview.ID(
                rawValue: CloudSurfaceIdentity.workspaceID(
                    machineID: machineID,
                    remoteWorkspaceID: remoteWorkspaceID
                )
            ),
            macDeviceID: hostID,
            macDisplayName: displayName,
            name: name,
            currentDirectory: currentDirectory,
            terminals: terminals.map { terminal in
                MobileTerminalPreview(
                    id: MobileTerminalPreview.ID(
                        rawValue: CloudSurfaceIdentity.surfaceID(
                            machineID: machineID,
                            terminalID: terminal.id
                        )
                    ),
                    name: terminal.name.flatMap { $0.isEmpty ? nil : $0 } ?? terminal.id,
                    isReady: true
                )
            }
        )
    }
}
