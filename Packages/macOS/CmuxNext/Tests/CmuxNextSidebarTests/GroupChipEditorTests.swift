import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// cx-rcby (Lawrence 2026-10-08: "new group is very ugly, the creation
/// animation is very bad too. make groups like this", the Chrome tab group
/// chip and its editor bubble): the header is a chip with no member count,
/// a more button on hover and the chevron; the chip, the more button and a
/// right-click open one editor whose name, color and rows go out as intents
/// and App actions; a group the store gives a new id keeps its header view,
/// so a new group moves in once.
@MainActor @Suite struct GroupChipEditorTests {
    final class Harness {
        let window: NSWindow
        let sidebar: SidebarView
        var intents: [SidebarIntent] = []
        var items: [(GroupID, String)] = []

        init(sections: [SidebarSection] = fixture()) {
            let model = SidebarModel(sections: sections, activeWorkspaceID: id("a"))
            sidebar = SidebarView(model: model)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            sidebar.frame = window.contentView!.bounds
            window.contentView!.addSubview(sidebar)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            sidebar.list.groupEditor.ordersFront = false
            model.onIntent = { [unowned self] intent in
                self.intents.append(intent)
                model.apply(intent)
            }
            sidebar.list.onGroupEditorItem = { [unowned self] group, item in self.items.append((group, item)) }
        }

        var list: SidebarListView { sidebar.list }

        func header(_ group: GroupID) throws -> GroupHeaderRowView {
            let view = try #require(list.rowViews[.group(group)] as? GroupHeaderRowView)
            view.layoutSubtreeIfNeeded()
            return view
        }
    }

    @Test func theHeaderShowsNoMemberCount() throws {
        let h = Harness()
        let header = try h.header(g1)
        let shown = header.allSubviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }.map(\.stringValue)
        #expect(!shown.contains("3"), "no count on the chip row: \(shown)")
    }

    @Test func theMoreButtonShowsOnHoverOnlyAndTheNameKeepsItsWidth() throws {
        let h = Harness()
        let header = try h.header(g1)
        header.isHovered = false
        header.layoutSubtreeIfNeeded()
        let rest = header.titleFrame
        #expect(header.moreButton.isHidden)
        header.isHovered = true
        header.layoutSubtreeIfNeeded()
        #expect(!header.moreButton.isHidden)
        #expect(header.titleFrame == rest)
        #expect(header.labelFrame.contains(NSPoint(x: header.moreButton.frame.midX, y: header.moreButton.frame.midY)), "inside the chip")
    }

    @Test func theMoreButtonAndARightClickOpenTheEditor() throws {
        let h = Harness()
        let header = try h.header(g1)
        header.isHovered = true
        header.layoutSubtreeIfNeeded()
        header.moreButton.performClick(nil)
        #expect(h.list.groupEditor.shownGroup == g1)
        h.list.groupEditor.hide()
        #expect(h.list.groupEditor.shownGroup == nil)

        let row = try #require(h.list.displayed.row(for: .group(g1)))
        let point = h.list.convert(NSPoint(x: h.list.frame(for: row).midX, y: h.list.frame(for: row).midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(h.list.menu(for: event) == nil, "the editor, not a menu")
        #expect(h.list.groupEditor.shownGroup == g1)
    }

    @Test func theEditorOpensWithTheNameAndTheChosenColor() throws {
        let h = Harness()
        h.list.groupEditing.open(g1)
        let bubble = try #require(h.list.groupEditor.bubble)
        #expect(bubble.nameField.stringValue == "G1")
        #expect(bubble.swatches.map(\.color) == GroupColor.editorOrder)
        #expect(bubble.swatches.first { $0.isChosen }?.color == .purple)
        #expect(try h.header(g1).isEditing)
    }

    @Test func nameAndColorGoOutAsIntentsAndClosingEndsTheEditor() throws {
        let h = Harness()
        h.list.groupEditing.open(g1)
        let bubble = try #require(h.list.groupEditor.bubble)
        bubble.pick(.red)
        #expect(h.intents.contains(.setGroupColor(g1, .red)))
        bubble.nameField.stringValue = "Frontend"
        bubble.dismiss()
        let tail = h.intents.suffix(2)
        #expect(Array(tail) == [.renameGroup(g1, "Frontend"), .groupEditorEnded(g1)], "\(h.intents)")
        #expect(h.list.groupEditor.shownGroup == nil)
        #expect(try h.header(g1).isEditing == false)
    }

    @Test func anEmptyOrUnchangedNameSendsNoRename() throws {
        let h = Harness()
        h.list.groupEditing.open(g1)
        let bubble = try #require(h.list.groupEditor.bubble)
        bubble.nameField.stringValue = "   "
        bubble.dismiss()
        #expect(!h.intents.contains { if case .renameGroup = $0 { true } else { false } })
        #expect(h.intents.last == .groupEditorEnded(g1))
    }

    @Test func aRowGoesToTheAppWithTheGroupAndClosesTheEditor() throws {
        let h = Harness()
        h.list.groupEditing.open(g1)
        let bubble = try #require(h.list.groupEditor.bubble)
        bubble.press("workspaceGroup.newWorkspace")
        #expect(h.items.map(\.0) == [g1])
        #expect(h.items.map(\.1) == ["workspaceGroup.newWorkspace"])
        #expect(h.list.groupEditor.shownGroup == nil)
    }

    @Test func theStandardRowsAreTheChromeEditorsActions() {
        let ids = SidebarContainerView.standardGroupEditorItems().map { $0.map(\.id) }
        #expect(ids == [
            ["workspaceGroup.newWorkspace", "workspaceGroup.moveToNewWindow", "workspaceGroup.closeWorkspaces"],
            ["workspaceGroup.ungroup", "workspaceGroup.delete", SidebarGroupEditing.moreActionsItem],
        ])
    }

    /// The home daemon names a group the sidebar made: the same header view
    /// carries on under the new id, and an open editor follows it.
    @Test func aReidentifiedGroupKeepsItsHeaderAndItsEditor() throws {
        let h = Harness()
        let before = try h.header(g1)
        h.list.groupEditing.open(g1)
        var sections = fixture()
        let renamed = GroupID("G1-daemon")
        sections[1].nodes[1] = .group(SidebarGroup(id: renamed, name: "G1", color: .purple, workspaces: [w("g1"), w("g2"), w("g3")]))
        h.list.model.setSections(sections)
        h.list.reload(animated: true)
        #expect(h.list.rowViews[.group(renamed)] === before, "one header view, no leave and arrive")
        #expect(h.list.rowViews[.group(g1)] == nil)
        #expect(h.list.groupEditor.shownGroup == renamed)
    }

    @Test func aClickInTheListClosesTheEditorAndEndsIt() throws {
        let h = Harness()
        h.list.groupEditing.open(g1)
        let row = try #require(h.list.displayed.row(for: .workspace(id("b"))))
        let point = h.list.convert(NSPoint(x: h.list.frame(for: row).midX, y: h.list.frame(for: row).midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                    windowNumber: h.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        h.list.mouseDown(with: event)
        #expect(h.list.groupEditor.shownGroup == nil)
        #expect(h.intents.contains(.groupEditorEnded(g1)))
    }

    @Test func theEditorClosesWhenItsGroupIsGone() throws {
        let h = Harness()
        h.list.groupEditing.open(g1)
        var sections = fixture()
        sections[1].nodes.remove(at: 1)
        h.list.model.setSections(sections)
        h.list.reload(animated: false)
        #expect(h.list.groupEditor.shownGroup == nil)
    }
}
