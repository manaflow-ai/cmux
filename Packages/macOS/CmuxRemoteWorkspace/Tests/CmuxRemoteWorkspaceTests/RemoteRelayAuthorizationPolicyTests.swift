import CmuxCore
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("Remote relay authorization policy")
struct RemoteRelayAuthorizationPolicyTests {
    @Test("tmux surface mutations require exact in-workspace selectors")
    func tmuxSurfaceSelectors() {
        let policy = RemoteRelayAuthorizationPolicy()
        let workspaceID = UUID()
        let surfaceID = UUID()
        let allowed = policy.validate(
            method: "surface.send_text",
            parameters: [
                "workspace_id": workspaceID.uuidString,
                "surface_id": surfaceID.uuidString,
            ],
            ownerWorkspaceID: workspaceID,
            surfaceIDs: [surfaceID]
        )
        #expect(allowed == .allowed)

        let missingSurface = policy.validate(
            method: "surface.send_text",
            parameters: ["workspace_id": workspaceID.uuidString],
            ownerWorkspaceID: workspaceID,
            surfaceIDs: [surfaceID]
        )
        #expect(missingSurface == .denied(
            code: "remote_relay_surface_denied",
            message: "Relay method requires an explicit surface selector"
        ))
    }

    @Test("selectors cannot cross the authenticated workspace")
    func crossWorkspaceSelectorIsDenied() {
        let policy = RemoteRelayAuthorizationPolicy()
        let ownerID = UUID()
        let foreignID = UUID()
        let decision = policy.validate(
            method: "workspace.equalize_splits",
            parameters: ["workspace_id": foreignID.uuidString],
            ownerWorkspaceID: ownerID,
            surfaceIDs: []
        )
        #expect(decision == .denied(
            code: "remote_relay_workspace_denied",
            message: "Relay request targets a different workspace"
        ))
    }

    @Test("respawn planner quotes remote directories and classifies transports")
    func planner() {
        let planner = RemotePTYRespawnPlanner()
        let workspaceID = UUID()
        let sessionID = RemotePTYRespawnPlanner.defaultSessionID(
            workspaceID: workspaceID,
            panelID: UUID()
        )
        let plan = planner.plan(
            sessionID: sessionID,
            rawCommand: "claude --agent-id teammate",
            remoteWorkingDirectory: "/data00/it's here",
            previousSessionID: " old-session "
        )
        #expect(plan?.remoteCommand == "cd '/data00/it'\\''s here' && claude --agent-id teammate")
        #expect(plan?.previousSessionID == "old-session")
        #expect(planner.routing(isRemoteOwned: false, configuration: nil) == .local)

        let bakedSSH = WorkspaceRemoteConfiguration(
            transport: .ssh,
            terminalTransport: .ssh,
            destination: "vm+cmux@vm-ssh.freestyle.sh",
            port: 22,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            managedCloudVMID: "vm-base",
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "cmux-default-freestyle-sshd-v1",
            skipDaemonBootstrap: true
        )
        #expect(planner.routing(isRemoteOwned: true, configuration: bakedSSH) == .unsupportedRemote)
    }
}
