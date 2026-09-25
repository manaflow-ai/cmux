import CmuxCore
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("Remote relay authorization policy")
struct RemoteRelayAuthorizationPolicyTests {
    @Test("An SSH peer cannot start another local SSH workspace", arguments: [false, true])
    func sshWorkspaceCreationRemainsLocalOnly(withCommand: Bool) {
        let owner = UUID()
        var parameters: [String: Any] = ["workspace_id": owner.uuidString, "destination": "another-host"]
        if withCommand { parameters["initial_command"] = "echo remote-command" }
        let decision = RemoteRelayAuthorizationPolicy().validate(
            method: "workspace.ssh.open", parameters: parameters,
            ownerWorkspaceID: owner, surfaceIDs: []
        )
        guard case .denied = decision else {
            Issue.record("workspace.ssh.open must remain unavailable to remote relay callers")
            return
        }
    }

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

    @Test("authorization requires handler-owned selector keys and rejects local shell options")
    func rejectsFallbackAndLocalExecutionInputs() {
        let policy = RemoteRelayAuthorizationPolicy()
        let workspaceID = UUID()
        let surfaceID = UUID()

        #expect(policy.validate(
            method: "surface.read_text",
            parameters: [
                "workspace_id": workspaceID.uuidString,
                "panel_id": surfaceID.uuidString,
            ],
            ownerWorkspaceID: workspaceID,
            surfaceIDs: [surfaceID]
        ) == .denied(
            code: "remote_relay_surface_denied",
            message: "Relay method requires an explicit surface selector"
        ))

        #expect(policy.validate(
            method: "surface.send_text",
            parameters: [
                "workspace_id": workspaceID.uuidString,
                "surface_id": surfaceID.uuidString,
                "remote_context": "local",
            ],
            ownerWorkspaceID: workspaceID,
            surfaceIDs: [surfaceID]
        ) == .denied(
            code: "remote_relay_method_denied",
            message: "Relay parameter 'remote_context' is not permitted"
        ))

        #expect(policy.validate(
            method: "surface.send_text",
            parameters: [
                "workspace_id": workspaceID.uuidString,
                "surface_id": surfaceID.uuidString,
                "initial_input": "touch /tmp/pwned",
            ],
            ownerWorkspaceID: workspaceID,
            surfaceIDs: [surfaceID]
        ) == .denied(
            code: "remote_relay_method_denied",
            message: "Relay parameter 'initial_input' is not permitted"
        ))
    }

    @Test("workspace.current requires an exact owner selector")
    func currentRequiresWorkspaceID() {
        let policy = RemoteRelayAuthorizationPolicy()
        let owner = UUID()
        #expect(policy.validate(
            method: "workspace.current",
            parameters: ["preferred_workspace_id": owner.uuidString],
            ownerWorkspaceID: owner,
            surfaceIDs: []
        ) == .denied(
            code: "remote_relay_workspace_denied",
            message: "Relay method requires an explicit workspace selector"
        ))
    }

    @Test("relay notification delivery is confined to the targeted method")
    func notificationCreateCannotUseRehomingPath() {
        let policy = RemoteRelayAuthorizationPolicy()
        let workspaceID = UUID()
        let surfaceID = UUID()
        #expect(policy.validate(
            method: "notification.create",
            parameters: ["workspace_id": workspaceID.uuidString, "surface_id": surfaceID.uuidString],
            ownerWorkspaceID: workspaceID,
            surfaceIDs: [surfaceID]
        ) == .denied(
            code: "remote_relay_method_denied",
            message: "Relay method is not permitted"
        ))
        #expect(policy.validate(
            method: "notification.create_for_target",
            parameters: ["workspace_id": workspaceID.uuidString, "surface_id": surfaceID.uuidString],
            ownerWorkspaceID: workspaceID,
            surfaceIDs: [surfaceID]
        ) == .allowed)
        // `effects` can only turn the relay's own delivery off (every default
        // is true); it stays inside the targeted method's closed contract.
        #expect(policy.validate(
            method: "notification.create_for_target",
            parameters: [
                "workspace_id": workspaceID.uuidString,
                "surface_id": surfaceID.uuidString,
                "title": "Done",
                "effects": ["desktop": false],
            ],
            ownerWorkspaceID: workspaceID,
            surfaceIDs: [surfaceID]
        ) == .allowed)
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
