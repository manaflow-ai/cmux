import Foundation
import Testing
@testable import CmuxCore

@Suite("WorkspaceRemoteScope inheritance")
struct WorkspaceRemoteScopeInheritanceTests {
    private let memberId = UUID()
    private let nonMemberId = UUID()

    private func inherits(
        scope: WorkspaceRemoteScope,
        policy: WorkspaceRemoteInheritance
    ) -> Bool {
        scope.allowsInheritance(policy: policy) { id in
            id == memberId
        }
    }

    @Test("always inherits for configured workspace and pane scopes")
    func alwaysPolicy() {
        #expect(inherits(scope: .workspace, policy: .always))
        #expect(inherits(scope: .pane, policy: .always))
    }

    @Test("never does not inherit under any scope")
    func neverPolicy() {
        #expect(!inherits(scope: .workspace, policy: .never))
        #expect(!inherits(scope: .pane, policy: .never))
    }

    @Test("workspace scope inherits from source-pane policy regardless of source")
    func workspaceScopeSourcePanePolicy() {
        #expect(inherits(scope: .workspace, policy: .fromSourcePane(nil)))
        #expect(inherits(scope: .workspace, policy: .fromSourcePane(memberId)))
        #expect(inherits(scope: .workspace, policy: .fromSourcePane(nonMemberId)))
    }

    @Test("pane scope inherits only from tracked source panes")
    func paneScopeSourcePanePolicy() {
        #expect(!inherits(scope: .pane, policy: .fromSourcePane(nil)))
        #expect(inherits(scope: .pane, policy: .fromSourcePane(memberId)))
        #expect(!inherits(scope: .pane, policy: .fromSourcePane(nonMemberId)))
    }
}

@Suite("WorkspaceRemoteConfiguration scope copy")
struct WorkspaceRemoteConfigurationScopeCopyTests {
    private func configuration(scope: WorkspaceRemoteScope) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            transport: .ssh,
            destination: "user@host",
            port: 2222,
            identityFile: "~/id_ed25519",
            scope: scope,
            sshOptions: ["StrictHostKeyChecking=no"],
            localProxyPort: 32000,
            relayPort: 42000,
            relayID: "relay-id",
            relayToken: String(repeating: "a", count: 64),
            localSocketPath: "/tmp/cmux.sock",
            ownerWorkspaceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            managedCloudVMID: "managed-vm",
            terminalStartupCommand: "ssh user@host",
            foregroundAuthToken: "foreground-token",
            agentSocketPath: "/tmp/agent.sock",
            daemonWebSocketEndpoint: WorkspaceRemoteWebSocketDaemonEndpoint(
                url: "wss://daemon.example.invalid/session",
                headers: ["X-Test": "1"],
                token: "daemon-token",
                sessionId: "daemon-session",
                expiresAtUnix: 1_700_000_000
            ),
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "daemon-slot",
            skipDaemonBootstrap: true
        )
    }

    @Test("withScope changes only the scope")
    func withScopeChangesOnlyScope() {
        let paneScoped = configuration(scope: .pane)
        let workspaceScoped = paneScoped.withScope(.workspace)

        #expect(workspaceScoped.scope == .workspace)
        #expect(workspaceScoped.withScope(.pane) == paneScoped)
    }

    @Test("withScope is identity when the scope already matches")
    func withScopeIsIdentityForMatchingScope() {
        let workspaceScoped = configuration(scope: .workspace)

        #expect(workspaceScoped.withScope(.workspace) == workspaceScoped)
    }
}
