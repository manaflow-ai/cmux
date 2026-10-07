import AppKit
import Testing
@testable import CmuxNextSidebar

/// Keyboard on group headers (cx-qno.17): Up/Down stop on a group header as
/// well as on workspaces (focus, not selection: SIDEBAR-SELECTION-ONE-MODEL
/// keeps one selection); Left on a member goes to its header, Left on an
/// open header collapses it; Right opens a closed header, then enters its
/// first member; Return on a focused header renames the group.
@MainActor @Suite struct GroupHeaderKeyboardTests {
    final class Harness {
        let window: NSWindow
        let sidebar: SidebarView
        let model: SidebarModel
        var list: SidebarListView { sidebar.list }

        init(active: String) {
            model = SidebarModel(sections: fixture(), activeWorkspaceID: id(active))
            sidebar = SidebarView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            sidebar.frame = window.contentView!.bounds
            window.contentView!.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            model.onIntent = { [unowned model] intent in model.apply(intent) }
        }

        func key(_ scalar: Int) {
            let chars = String(Character(UnicodeScalar(scalar)!))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)!
            list.keyDown(with: event)
        }
        func up() { key(NSUpArrowFunctionKey) }
        func down() { key(NSDownArrowFunctionKey) }
        func left() { key(NSLeftArrowFunctionKey) }
        func right() { key(NSRightArrowFunctionKey) }
        func enter() { key(0x0D) }
    }

    @Test func upFromAGroupsFirstMemberStopsOnItsHeader() {
        let h = Harness(active: "g1")
        h.up()
        #expect(h.list.focusedGroup == g1)
        #expect(h.model.activeWorkspaceID == id("g1"), "focus on a header is not a selection")
        h.up()
        #expect(h.list.focusedGroup == nil)
        #expect(h.model.activeWorkspaceID == id("a"))
    }

    @Test func downFromALooseRowStopsOnTheNextHeaderThenEntersIt() {
        let h = Harness(active: "a")
        h.down()
        #expect(h.list.focusedGroup == g1)
        h.down()
        #expect(h.list.focusedGroup == nil)
        #expect(h.model.activeWorkspaceID == id("g1"))
    }

    @Test func leftAndRightCollapseExpandAndEnter() {
        let h = Harness(active: "g2")
        h.left()
        #expect(h.list.focusedGroup == g1, "Left on a member goes to its header")
        h.left()
        #expect(h.model.group(g1)?.isCollapsed == true, "Left on an open header collapses")
        h.right()
        #expect(h.model.group(g1)?.isCollapsed == false, "Right on a closed header expands")
        h.right()
        #expect(h.list.focusedGroup == nil)
        #expect(h.model.activeWorkspaceID == id("g1"), "Right on an open header enters its first member")
    }

    @Test func aCollapsedGroupIsOneStop() {
        let h = Harness(active: "b")
        h.down()
        #expect(h.list.focusedGroup == g2, "G2 is collapsed; its header is the stop")
        h.down()
        #expect(h.list.focusedGroup == nil)
        #expect(h.model.activeWorkspaceID == id("c"), "the hidden members are skipped")
    }

    @Test func returnOnAFocusedHeaderRenamesTheGroup() {
        let h = Harness(active: "g1")
        h.up()
        h.enter()
        #expect(h.list.inlineRename.session?.key == .group(g1))
        h.list.inlineRename.end(commit: false)
    }
}
