import AppKit
import CmuxNextAgentPane
@testable import CmuxNextLayout
import Testing

/// Review of #28044 at bd2b918d: the right column was read from the active screen's frames, so a
/// subagent open still queued when the person switched to another screen read the chat's screen as
/// empty and split again beside panes already there. It reads the chat's own screen now.
@MainActor struct RightColumnScreenTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    @Test func aChatOnAScreenThePersonSwitchedAwayFromKeepsItsRightColumn() throws {
        _ = NSApplication.shared
        let screens = [
            LayoutScreen(id: "s1", name: "chat", layout: .columns([LayoutColumn(id: "c1", width: 1,
                root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("chat"), b: .leaf("diff")))])),
            LayoutScreen(id: "s2", name: "other", layout: .columns([LayoutColumn(id: "c2", width: 1, root: .leaf("other"))])),
        ]
        let model = LayoutModel(screens: screens, activeScreenID: "s1", focusedPane: "chat")
        let root = LayoutRootView(model: model, contentProvider: Panes())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        #expect(RightColumnPlacement.column(beside: PaneID("chat"), frames: root.navigationFrames) == ["diff"])

        // The person switches to the other screen while an open for the chat waits its turn.
        model.selectScreen("s2")
        root.syncWithModel()
        root.layoutSubtreeIfNeeded()
        try #require(root.screenViews["s1"]?.isHidden == true)
        #expect(RightColumnPlacement.column(beside: PaneID("chat"), frames: root.navigationFrames).isEmpty,
                "fixture: the active screen's frames hold none of the chat's screen")
        #expect(RightColumnPlacement.column(beside: PaneID("chat"), frames: root.navigationFrames(ofScreenContaining: "chat")) == ["diff"],
                "the chat's right column read empty from another screen, so the open would split again")
    }
}
