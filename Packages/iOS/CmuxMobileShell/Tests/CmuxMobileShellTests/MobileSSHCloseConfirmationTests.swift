@testable import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSSH
import Foundation
import Testing

/// Closing a workspace row ends a server primitive on an SSH computer. The
/// rule: kinds that outlive the phone (tmux, cmux-tui) always ask, naming
/// what ends and where; a shell, which only lives for the phone's channel,
/// closes in one tap. Mac rows keep the Mac question.
@MainActor
@Suite struct MobileSSHCloseConfirmationTests {
    @Test func tmuxAsksToEndTheSession() throws {
        let confirmation = try #require(
            MobileWorkspaceCloseConfirmation.ssh(kind: .tmux, workspaceName: "vt-main", hostName: "devbox")
        )
        #expect(confirmation.title == "End “vt-main” on devbox?")
        #expect(confirmation.message == "This closes the tmux session and stops everything running in it, including anything open on other devices.")
        #expect(confirmation.actionTitle == "End Session")
    }

    @Test func cmuxTUIAsksToCloseTheWorkspace() throws {
        let confirmation = try #require(
            MobileWorkspaceCloseConfirmation.ssh(kind: .cmuxTUI, workspaceName: "api", hostName: "devbox")
        )
        #expect(confirmation.title == "End “api” on devbox?")
        #expect(confirmation.message.hasPrefix("This closes the workspace and its terminals"))
        #expect(confirmation.actionTitle == "Close Workspace")
    }

    /// A shell ends when the phone disconnects anyway, and an id the runtime
    /// cannot parse closes nothing: neither asks.
    @Test func shellAndUnknownKindCloseInOneTap() {
        #expect(MobileWorkspaceCloseConfirmation.ssh(kind: .shell, workspaceName: "Shell 1", hostName: "devbox") == nil)
        #expect(MobileWorkspaceCloseConfirmation.ssh(kind: nil, workspaceName: "x", hostName: "devbox") == nil)
    }

    /// Through the store, with aggregation re-keying rows (a Mac and the SSH
    /// computer both live): each row resolves by its kind, names the saved
    /// host, and the Mac row keeps the Mac question.
    @Test func storeResolvesEachRowByKindAndHost() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-ssh-close-\(UUID().uuidString)")
        let computers = MobileSSHComputers(directory: dir)
        let host = SSHHostRecord(name: "devbox", endpoint: SSHEndpoint(host: "127.0.0.1", port: 1, username: "nobody"))
        try await computers.saveHost(host)
        let store = MobileShellComposite(
            isSignedIn: true,
            pairedMacStore: MobileShellDemoContentTests.RecordingPairedMacStore(),
            identityProvider: StaticIdentityProvider(userID: "ssh-close-user"),
            teamIDProvider: { "team-a" },
            sshComputers: computers
        )
        store.setWorkspaceStatesForTesting(
            [
                "mac-a": MacWorkspaceState(
                    macDeviceID: "mac-a",
                    displayName: "Desk Mac",
                    workspaces: [MobileWorkspacePreview(id: "ws-1", macDeviceID: "mac-a", name: "Mac workspace", terminals: [])],
                    status: .connected,
                    workspaceSnapshotIsAuthoritative: true
                ),
            ],
            foregroundMacDeviceID: "mac-a"
        )
        let computerID = MobileSSHIdentifier(computerOf: host.id).rawValue
        let locals = [
            "tmux:laptop-work": "laptop-work",
            "tui:main/k1": "api",
            "shell:1": "Shell 1",
        ]
        store.sshPublishWorkspaceState(MacWorkspaceState(
            macDeviceID: computerID,
            displayName: host.name,
            workspaces: locals.keys.sorted().map { local in
                MobileWorkspacePreview(
                    id: .init(rawValue: MobileSSHIdentifier(host: host.id, local: local).rawValue),
                    macDeviceID: computerID,
                    name: locals[local] ?? local,
                    terminals: []
                )
            },
            workspaceGroupsAreAuthoritative: true,
            status: .connected,
            workspaceSnapshotIsAuthoritative: true,
            actionCapabilities: MobileWorkspaceActionCapabilities(supportsCloseActions: true)
        ))

        func row(_ local: String) throws -> MobileWorkspacePreview.ID {
            let scoped = MobileSSHIdentifier(host: host.id, local: local).rawValue
            return try #require(store.workspaces.first { $0.rpcWorkspaceID.rawValue == scoped }).id
        }

        let tmux = try #require(store.workspaceCloseConfirmation(id: try row("tmux:laptop-work")))
        #expect(tmux.title == "End “laptop-work” on devbox?")
        #expect(tmux.actionTitle == "End Session")
        let tui = try #require(store.workspaceCloseConfirmation(id: try row("tui:main/k1")))
        #expect(tui.title == "End “api” on devbox?")
        #expect(tui.actionTitle == "Close Workspace")
        #expect(store.workspaceCloseConfirmation(id: try row("shell:1")) == nil)

        let macRow = try #require(store.workspaces.first { $0.macDeviceID == "mac-a" })
        #expect(store.workspaceCloseConfirmation(id: macRow.id) == .macWorkspace)
    }
}
