import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// #27700: a pinned group could not be unpinned from its header. Its pin was only a mark and a
/// click anywhere on the bar folded the group, so repeated header clicks never unpinned it. A
/// hovered pinned header now shows an Unpin button, as a pinned workspace row does, that runs the
/// editor's Unpin Group; an unpinned header shows none (Leo 2026-10-21: "no empty pin symbol").
@MainActor @Suite(.serialized, .closesItsWindows) struct GroupHeaderUnpinButtonTests {
    final class Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let sidebar: SidebarView
        let id = GroupID("grp-unpin")
        private(set) var items: [(GroupID, String)] = []
        private(set) var intents: [SidebarIntent] = []

        init(pinned: Bool) throws {
            let store = DaemonStore()
            store.apply(snapshot: DaemonTree(workspaces: [
                WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, resourceID: ResourceID(rawValue: "ws-0"), name: "w0"),
            ]))
            let section = try #require(SidebarMapping.shared.sections(store.sidebarSections,
                                                                       machine: SidebarMachine(id: .local, name: "This Mac", kind: .local)).first)
            let group = SidebarGroup(id: id, name: "Chief agents", color: .blue, isPinned: pinned, workspaces: section.workspaces)
            sidebar = SidebarView(model: SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: section.kind, nodes: [.group(group)])]),
                                  design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
            sidebar.list.onGroupEditorItem = { [unowned self] group, item in items.append((group, item)) }
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            sidebar.list.reload(animated: false)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.model.onIntent = { [unowned self] intent in intents.append(intent) }
        }

        /// The header, wired and hovered (its actions show).
        func hoveredHeader() throws -> GroupHeaderRowView {
            let header = try #require(sidebar.list.rowViews[.group(id)] as? GroupHeaderRowView)
            sidebar.list.wire(header, key: .group(id))
            header.isHovered = true
            header.needsLayout = true
            header.layoutSubtreeIfNeeded()
            return header
        }

        /// A click on `button` as the window routes it: the row's hit test picks the view, then its own action
        /// runs (not performClick, which spins a nested event loop on macOS 27, `GroupPaletteDefaultTests`).
        func click(_ button: NSButton, in header: GroupHeaderRowView) throws {
            let center = header.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: header.superview)
            try #require(header.hitTest(center) === button, "the click at the button's center does not reach it")
            #expect(button.sendAction(button.action, to: button.target), "the button has no action")
        }

        var toggles: Int {
            intents.filter { if case .toggleCollapse(.group(id)) = $0 { true } else { false } }.count
        }
    }

    @Test func aClickOnAPinnedHeadersUnpinButtonUnpinsAndDoesNotFold() throws {
        let harness = try Harness(pinned: true)
        defer { harness.window.close() }
        let header = try harness.hoveredHeader()
        let pin = header.pinButton
        #expect(!pin.isHidden && pin.alphaValue > 0, "a hovered pinned header shows no Unpin button")
        #expect(pin.accessibilityLabel() == GroupEditorStrings.unpin)
        for other in [header.addButton, header.moreButton] {
            #expect(!pin.frame.intersects(other.frame), "the Unpin button overlaps \(other)")
        }
        #expect(pin.frame.maxX <= header.addButton.frame.minX, "the Unpin button sits left of the +")
        try harness.click(pin, in: header)
        #expect(harness.items.map(\.1) == ["workspaceGroup.togglePin"], "\(harness.items)")
        #expect(harness.items.first?.0 == harness.id)
        #expect(harness.toggles == 0, "the Unpin click folded the group: \(harness.intents)")
    }

    /// The editor's Pin row was titled when it opened: an Unpin from the header closes it, so that row
    /// cannot read Unpin Group and pin the group again.
    @Test(.enabled("the editor bubble is a window on screen") { await GroupPaletteDefaultTests.hasDisplay() })
    func unpinningFromTheHeaderClosesAnOpenGroupEditor() throws {
        let harness = try Harness(pinned: true)
        defer { SidebarMenuAnchorTests.close(harness.sidebar, harness.window) } // the editor's bubble is a window too
        harness.window.orderFrontRegardless() // the editor's bubble opens from a window on a screen
        harness.sidebar.list.groupEditing.open(harness.id, from: .moreButton)
        try #require(harness.sidebar.list.groupEditor.isVisible)
        let header = try harness.hoveredHeader()
        try harness.click(header.pinButton, in: header)
        #expect(!harness.sidebar.list.groupEditor.isVisible, "the editor stayed open with a stale Unpin Group row")
        #expect(harness.items.map(\.1) == ["workspaceGroup.togglePin"], "\(harness.items)")
    }

    @Test func aPinnedHeaderAtRestShowsNoUnpinButton() throws {
        let harness = try Harness(pinned: true)
        defer { harness.window.close() }
        let header = try harness.hoveredHeader()
        header.isHovered = false
        header.needsLayout = true
        header.layoutSubtreeIfNeeded()
        #expect(header.pinButton.isHidden || header.pinButton.alphaValue == 0)
    }

    @Test func anUnpinnedHeaderShowsNoPinButtonOnHover() throws {
        let harness = try Harness(pinned: false)
        defer { harness.window.close() }
        let header = try harness.hoveredHeader()
        #expect(header.pinButton.isHidden || header.pinButton.alphaValue == 0, "an unpinned header drew an empty pin")
        #expect(!header.addButton.isHidden, "the + still shows on hover")
    }
}
