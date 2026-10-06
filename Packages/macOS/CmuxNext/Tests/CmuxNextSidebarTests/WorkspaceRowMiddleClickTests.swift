import AppKit
import Testing
@testable import CmuxNextSidebar

/// MIDDLE-CLICK-CLOSES-WORKSPACE: a middle click on a workspace row closes
/// that workspace through the shared close intent (the row's x, so the same
/// confirmation); on a group row it does nothing.
@MainActor @Suite struct WorkspaceRowMiddleClickTests {
    final class Harness {
        let window: NSWindow
        let sidebar: SidebarView
        var intents: [SidebarIntent] = []

        init() {
            let model = SidebarModel(sections: fixture(), activeWorkspaceID: id("a"))
            sidebar = SidebarView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            sidebar.frame = window.contentView!.bounds
            window.contentView!.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            model.onIntent = { [unowned self] intent in self.intents.append(intent) }
        }

        var list: SidebarListView { sidebar.list }

        /// The middle of `key`'s row, in list coordinates.
        func point(_ key: SidebarRowKey) -> NSPoint {
            let frame = list.frame(for: list.displayed.row(for: key)!)
            return NSPoint(x: frame.midX, y: frame.midY)
        }

        func middleClick(down: SidebarRowKey, up: SidebarRowKey) {
            list.middleClick.pressDown(at: point(down), in: list)
            list.middleClick.pressUp(at: point(up), in: list)
        }
    }

    @Test func middleClickOnAWorkspaceRowClosesThatWorkspace() {
        let h = Harness()
        h.middleClick(down: .workspace(id("b")), up: .workspace(id("b")))
        #expect(h.intents == [.close([id("b")])])
    }

    @Test func middleClickClosesOnlyTheClickedRowNotTheSelection() {
        let h = Harness()
        h.list.model.toggleSelection(id("a"))
        h.list.model.toggleSelection(id("c"))
        h.middleClick(down: .workspace(id("b")), up: .workspace(id("b")))
        #expect(h.intents == [.close([id("b")])])
    }

    @Test func middleClickOnAGroupRowDoesNothing() {
        let h = Harness()
        h.middleClick(down: .group(g1), up: .group(g1))
        #expect(h.intents.isEmpty)
    }

    @Test func middlePressThatLeavesTheRowClosesNothing() {
        let h = Harness()
        h.middleClick(down: .workspace(id("a")), up: .workspace(id("b")))
        #expect(h.intents.isEmpty)
    }
}
