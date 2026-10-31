import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// #27701: Shift-click across pinned workspaces, as cmux classic. Shift-click selects every workspace drawn
/// between the anchor and the clicked one, pinned tiles and list rows alike; Cmd-click toggles any of them;
/// Cmd-Shift-click adds the range to the selection. Before, a press on a pinned tile only showed its workspace,
/// and a Shift-click on a row from a shown pinned workspace selected that row alone (the range had no anchor).
/// Each case runs with Pinned in the band above the list and in the list's block (the sidebar document).
@MainActor @Suite(.closesItsWindows, .serialized)
struct SidebarShiftClickPinnedTests {
    static let pinned = [LayoutItemID("itm_p1"), LayoutItemID("itm_p2")]
    static func pinnedWorkspace(_ item: LayoutItemID) -> WorkspaceID { WorkspaceID("ws-\(item.rawValue.dropFirst(4))") }
    static let rows = (1...3).map { WorkspaceID("ws-\($0)") }
    static let blockKey = SidebarRowKey.block(SidebarLayoutDocument.pinnedSectionID.rawValue)

    final class Harness {
        let model: SidebarModel
        let sidebar: SidebarView
        let window: NSWindow
        let hold: SidebarSelectionHold
        let document: Bool
        var list: SidebarListView { sidebar.list }

        init(document: Bool) {
            self.document = document
            let pinnedSection = LayoutSection(id: SidebarLayoutDocument.pinnedSectionID, region: .top, look: .builtIn, arrangement: .list,
                                              items: SidebarShiftClickPinnedTests.pinned.map { LayoutItem(id: $0, ref: .workspace("s:\($0.rawValue)")) })
            let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
            let listed = CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: SidebarShiftClickPinnedTests.rows.map {
                SidebarNode.workspace(SidebarWorkspace(id: $0, title: $0.rawValue))
            })
            if document {
                let block = CmuxNextSidebar.SidebarSection(kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.pinnedSectionID.rawValue)), nodes: [])
                model = SidebarModel(sections: [block, listed])
                model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
            } else {
                model = SidebarModel(sections: [listed])
            }
            model.layout = SidebarLayoutDocument(sections: [pinnedSection])
            for item in SidebarShiftClickPinnedTests.pinned {
                var info = SidebarItemInfo(title: item.rawValue, symbol: "terminal")
                info.workspace = SidebarShiftClickPinnedTests.pinnedWorkspace(item)
                model.itemInfo[item] = info
            }
            hold = SidebarSelectionHold(model: model)
            sidebar = SidebarView(model: model, design: DesignSettings.shared)
            sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 480)
            window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(sidebar)
            window.orderFrontRegardless()
            // The App's echo: showing a pinned workspace selects its tile (`SidebarNavigation.selectedItem`), and the
            // window's selection reaches the sidebar through the selection hold, as in the app.
            model.onIntent = { [unowned self] intent in
                switch intent {
                case let .activateItem(item, _): hold.offer(.topItem(item))
                case let .select(id):
                    let tile = SidebarShiftClickPinnedTests.pinned.first { SidebarShiftClickPinnedTests.pinnedWorkspace($0) == id }
                    hold.offer(tile.map(SidebarItem.topItem) ?? .workspace(id))
                default: model.apply(intent)
                }
            }
            sidebar.renderNow()
            settle()
            if document { list.reload(animated: false); settle() }
        }

        func settle() {
            sidebar.renderNow()
            sidebar.layoutSubtreeIfNeeded()
            list.fitToClip()
            sidebar.layoutSubtreeIfNeeded()
            list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        }

        var region: SidebarRegionView? {
            document ? (list.rowViews[SidebarShiftClickPinnedTests.blockKey] as? SidebarBlockRowView)?.region : sidebar.aboveRegion
        }

        func tile(_ item: LayoutItemID) throws -> SidebarItemRowView {
            let view = try #require(region?.itemView(item), "Pinned draws no \(item.rawValue) tile")
            view.layoutSubtreeIfNeeded()
            return view
        }

        func event(_ type: NSEvent.EventType, at point: NSPoint, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        /// A click on pinned tile `item`, with `flags` held.
        func click(_ item: LayoutItemID, _ flags: NSEvent.ModifierFlags = []) throws {
            let tile = try tile(item)
            let center = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)
            tile.mouseDown(with: try event(.leftMouseDown, at: center, flags))
            tile.mouseUp(with: try event(.leftMouseUp, at: center, flags))
            settle()
        }

        /// A click on list row `id`, with `flags` held.
        func click(_ id: WorkspaceID, _ flags: NSEvent.ModifierFlags = []) throws {
            let row = try #require(list.rowViews[.workspace(id)], "the list draws no \(id.rawValue) row")
            let center = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            list.mouseDown(with: try event(.leftMouseDown, at: center, flags))
            list.mouseUp(with: try event(.leftMouseUp, at: center, flags))
            settle()
        }

        var selected: [String] { model.selection.map(\.rawValue).sorted() }

        /// Whether pinned tile `item` shows as selected (the shown tile or the multi-selection's fill), as VoiceOver reads it.
        func drawsSelected(_ item: LayoutItemID) throws -> Bool { try tile(item).isAccessibilitySelected() }
    }

    @Test(arguments: [false, true])
    func shiftClickFromAShownPinnedWorkspaceSelectsTheRangeIntoTheList(_ document: Bool) throws {
        let harness = Harness(document: document)
        defer { harness.window.close() }
        try harness.click(Self.pinned[0])
        #expect(harness.selected == ["ws-p1"], "a click on a pinned tile did not select its workspace")
        try harness.click(Self.rows[1], .shift)
        #expect(harness.selected == ["ws-1", "ws-2", "ws-p1", "ws-p2"], "the Shift range did not run from the pinned tile")
        #expect(try harness.drawsSelected(Self.pinned[1]), "the pinned tile inside the range draws unselected")
        // Close, drag and Move act on the whole range, the pinned workspaces too, in drawn order.
        #expect(harness.model.orderedSelection.map(\.rawValue) == ["ws-p1", "ws-p2", "ws-1", "ws-2"])
    }

    @Test(arguments: [false, true])
    func shiftClickOnAPinnedTileSelectsTheRangeFromAListRow(_ document: Bool) throws {
        let harness = Harness(document: document)
        defer { harness.window.close() }
        try harness.click(Self.rows[2])
        try harness.click(Self.pinned[1], .shift)
        #expect(harness.selected == ["ws-1", "ws-2", "ws-3", "ws-p2"], "a Shift-click on a pinned tile did not select the range")
        #expect(harness.model.activeWorkspaceID == Self.rows[2], "a Shift-click switched the shown workspace")
        #expect(try harness.drawsSelected(Self.pinned[1]))
        #expect(try !harness.drawsSelected(Self.pinned[0]))
    }

    @Test(arguments: [false, true])
    func cmdClickTogglesAPinnedTileAndCmdShiftClickAddsTheRange(_ document: Bool) throws {
        let harness = Harness(document: document)
        defer { harness.window.close() }
        try harness.click(Self.rows[2])
        try harness.click(Self.pinned[0], .command)
        #expect(harness.selected == ["ws-3", "ws-p1"], "Cmd-click on a pinned tile did not add it")
        try harness.click(Self.pinned[1], [.command, .shift])
        #expect(harness.selected == ["ws-3", "ws-p1", "ws-p2"], "Cmd-Shift-click did not add the range to the selection")
        try harness.click(Self.pinned[0], .command)
        #expect(harness.selected == ["ws-3", "ws-p2"], "Cmd-click on a selected pinned tile did not remove it")
        #expect(try !harness.drawsSelected(Self.pinned[0]))
    }

    @Test(arguments: [false, true])
    func shiftDownFromAShownPinnedWorkspaceExtendsIntoTheList(_ document: Bool) throws {
        let harness = Harness(document: document)
        defer { harness.window.close() }
        try harness.click(Self.pinned[1])
        harness.window.makeFirstResponder(harness.list)
        let arrow = "\u{F701}" // NSDownArrowFunctionKey
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift, .numericPad, .function], timestamp: 0,
                                                 windowNumber: harness.window.windowNumber, context: nil, characters: arrow,
                                                 charactersIgnoringModifiers: arrow, isARepeat: false, keyCode: 125))
        harness.list.keyDown(with: down)
        harness.settle()
        #expect(harness.selected == ["ws-1", "ws-p2"], "Shift+Down from a shown pinned workspace did not extend into the list")
    }
}
