import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSidebar
import Testing

/// RECOVERABLE-BY-DEFAULT for pins (PINNED-ITEMS-END-TO-END P4, nxdog63-v2):
/// a user's pin or unpin shows an undo toast in its window, and Cmd-Z (the
/// toast undo key, TOAST-UNDO-KEY) runs it. Automation pins show none. The
/// window is never put on screen.
@MainActor
struct PinUndoToastTests {
    private static func pinToasts(_ window: NSWindow) -> [CmuxToast] {
        CmuxToastCenter.shared.toasts(in: window).filter { $0.id == PinCommands.undoToastID }
    }

    @Test func aUserPinShowsAnUndoToastAndCmdZUndoesIt() async throws {
        let owner = SidebarLayoutServiceTests.FakeOwner()
        let services = WorkspacePinTilesTests.services(owner: owner)
        let window = try #require(services.windows.openWindow(workspaces: [WorkspacePinTilesTests.id(1)])?.window)
        defer { window.close() }
        let commands = PinCommands(context: AppActionContext(services: services))
        try commands.setWorkspacePinned(WorkspacePinTilesTests.id(1), pinned: true, origin: .user)
        #expect(Self.pinToasts(window).map(\.message) == [PinStrings.workspacePinned])
        #expect(CmuxToastCenter.shared.runUndo(in: window), "Cmd-Z runs the toast")
        #expect(!services.sidebarLayout.document.isPinned(WorkspacePinTilesTests.ref(1)), "the pin is undone")
        for _ in 0..<300 { for call in owner.calls { owner.accept(call.key) }; await Task.yield() }
    }

    @Test func automationPinsShowNoToast() async throws {
        let owner = SidebarLayoutServiceTests.FakeOwner()
        let services = WorkspacePinTilesTests.services(owner: owner)
        let window = try #require(services.windows.openWindow(workspaces: [WorkspacePinTilesTests.id(1)])?.window)
        defer { window.close() }
        try PinCommands(context: AppActionContext(services: services)).setWorkspacePinned(WorkspacePinTilesTests.id(1), pinned: true, origin: .cli)
        #expect(Self.pinToasts(window).isEmpty)
        for _ in 0..<300 { for call in owner.calls { owner.accept(call.key) }; await Task.yield() }
    }
}
