import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct CreatedTerminalSelectionTests {
    @Test func localCreatedTerminalMatchesAfterAnonymousRowAdoptsMacIdentity() {
        let anonymousWorkspace = MobileWorkspacePreview(
            id: "workspace-main",
            name: "cmux",
            terminals: [MobileTerminalPreview(id: "terminal-new", name: "Terminal 2", isReady: false)]
        )
        let selection = CreatedTerminalSelection(
            workspace: anonymousWorkspace,
            fallbackMacDeviceID: "mac-main",
            fallbackInstanceTag: "ntab",
            terminalID: "terminal-new"
        )
        var stampedWorkspace = MobileWorkspacePreview(
            id: "workspace-main",
            macDeviceID: "mac-main",
            name: "cmux",
            terminals: [MobileTerminalPreview(id: "terminal-new", name: "Terminal 2", isReady: false)]
        )
        stampedWorkspace.macInstanceTag = "ntab"

        #expect(selection.matches(workspace: stampedWorkspace, allowsAnonymousForeground: false))
        stampedWorkspace.macInstanceTag = nil
        #expect(!selection.matches(workspace: stampedWorkspace, allowsAnonymousForeground: false))

        let anonymousWithFallback = CreatedTerminalSelection(
            workspace: anonymousWorkspace,
            fallbackMacDeviceID: "mac-main",
            terminalID: "terminal-new"
        )
        #expect(!anonymousWithFallback.matches(workspace: anonymousWorkspace, allowsAnonymousForeground: true))
        #expect(!anonymousWithFallback.matches(workspace: anonymousWorkspace, allowsAnonymousForeground: false))

        let anonymousSelection = CreatedTerminalSelection(
            workspace: anonymousWorkspace,
            terminalID: "terminal-new"
        )
        #expect(anonymousSelection.matches(workspace: anonymousWorkspace, allowsAnonymousForeground: true))
        #expect(!anonymousSelection.matches(workspace: anonymousWorkspace, allowsAnonymousForeground: false))

        var taggedWorkspace = anonymousWorkspace
        taggedWorkspace.macInstanceTag = "nightly"
        #expect(!anonymousSelection.matches(workspace: taggedWorkspace, allowsAnonymousForeground: true))
    }

    @Test func knownWorkspaceDoesNotBorrowFallbackInstanceTag() {
        let workspace = MobileWorkspacePreview(
            id: "workspace-main",
            macDeviceID: "mac-main",
            name: "cmux",
            terminals: [MobileTerminalPreview(id: "terminal-new", name: "Terminal 2")]
        )
        let selection = CreatedTerminalSelection(
            workspace: workspace,
            fallbackMacDeviceID: "mac-main",
            fallbackInstanceTag: "unrelated-sibling",
            terminalID: "terminal-new"
        )

        #expect(selection.macInstanceTag == nil)
    }

    @Test func remoteCreatedTerminalRemainsSelectedAfterRefresh() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let created = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.createdTerminal)

        store.createTerminal(in: MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID))
        await router.awaitTerminalCreateRequested()
        await waitUntilSelectedTerminal(store, is: created)
        #expect(store.selectedTerminalID == created)

        await store.refreshWorkspaces()

        #expect(store.selectedTerminalID == created)
    }

    private func waitUntilSelectedTerminal(
        _ store: MobileShellComposite,
        is terminalID: MobileTerminalPreview.ID
    ) async {
        for _ in 0..<50 where store.selectedTerminalID != terminalID {
            await Task.yield()
        }
    }
}
