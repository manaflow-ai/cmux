#if os(iOS) && canImport(CmuxMobileLinkFFI)
import CmuxMobileLinkFFI
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// Leo, 2026-11-21: "i lost connection ... and then it brought me out of the terminal tab ... multiple
/// issues to fix there". A View Only chat request that fails because the Mac's link is down must not
/// overwrite the Terminal / Chat face the person chose.
@MainActor @Suite(.serialized)
struct ReconnectKeepsFaceChoiceTests {
    struct LinkDown: Error {}

    @MainActor final class FailingBackend: WorkspaceCreationBackend, TerminalChatBackend {
        var asked = 0
        func canCreate(on macID: String) -> Bool { true }
        func options(on macID: String) -> WorkspaceCreationOptions { .basic }
        func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace { placeholder }
        func terminalChatListings(on macID: String) -> [TerminalChatListing] { [] }
        func openTerminalChat(harness: String, session: String, terminalTabID: String, on macID: String) async throws -> TerminalChatOpen {
            asked += 1
            throw LinkDown()
        }
    }

    @Test func aFailedChatRequestOnADownLinkKeepsTheChosenFace() async {
        let backend = FailingBackend()
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        store.workspaces = [Workspace(id: "w", macID: "mac", title: "relay", directory: "~/p",
                                      tabs: [TerminalChatToggleTests.terminal("s1", agent: "claude", session: "h-1")], lastActivityAt: Date())]
        let source = WorkspaceTabsSource(store: store, workspaceID: "w", creator: WorkspaceCreator(store: store, backend: backend))
        source.terminalChatToggleOn = { true }
        source.chosenFaces["s1"] = .chat
        store.macConnection["mac"] = .connecting
        source.openTerminalChatIfNeeded("s1")
        await TerminalChatToggleTests.settle { backend.asked > 0 }
        for _ in 0..<50 { await Task.yield() }
        #expect(backend.asked == 1)
        #expect(source.chosenFaces["s1"] == .chat, "the link's failure is not the person's choice")
    }

    @Test func aFailedChatRequestOnALiveLinkStillFallsBackToTheTerminal() async {
        let backend = FailingBackend()
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        store.workspaces = [Workspace(id: "w", macID: "mac", title: "relay", directory: "~/p",
                                      tabs: [TerminalChatToggleTests.terminal("s1", agent: "claude", session: "h-1")], lastActivityAt: Date())]
        let source = WorkspaceTabsSource(store: store, workspaceID: "w", creator: WorkspaceCreator(store: store, backend: backend))
        source.terminalChatToggleOn = { true }
        source.chosenFaces["s1"] = .chat
        store.macConnection["mac"] = .connected
        source.openTerminalChatIfNeeded("s1")
        await TerminalChatToggleTests.settle { source.chosenFaces["s1"] == .terminal }
        #expect(source.chosenFaces["s1"] == .terminal)
    }
}
#endif
