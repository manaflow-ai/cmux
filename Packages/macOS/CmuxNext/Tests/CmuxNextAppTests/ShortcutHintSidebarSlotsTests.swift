import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing
import CmuxNextTestSupport

/// Modifier-hold hints in the sidebar come from the same slot mapping Cmd-1…9 uses
/// (`SidebarItemOrder.number(for:_:)`): every digit that reaches a shown destination
/// has a chip on that destination, so Home and the App Store (Cmd-1, Cmd-2 with
/// `sidebar.numbering = allItems`) show theirs too (u4457: "i dont see cmd 1 and cmd 2 hints").
@MainActor @Suite(.closesItsWindows, .serialized)
struct ShortcutHintSidebarSlotsTests {
    private static func machine(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    /// The document's top block (Home, the App Store) drawn as a list row, as in the default sidebar.
    private static func topBlock() -> CmuxNextSidebar.SidebarSection {
        CmuxNextSidebar.SidebarSection(
            kind: .custom(SidebarCustomSection(id: SidebarLayoutDocument.topSectionID.rawValue, title: "", showsTitle: false)), nodes: [])
    }

    private static func layOut(_ sections: [CmuxNextSidebar.SidebarSection]) -> (SidebarModel, SidebarView, NSWindow) {
        let model = SidebarModel(sections: sections)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 100, width: 260, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(sidebar)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        return (model, sidebar, window)
    }

    /// Each digit 1…9 whose item is drawn has a chip frame; returns the digits that miss one.
    private static func digitsWithoutChip(_ model: SidebarModel, _ sidebar: SidebarView) -> [Int] {
        let settings = SidebarNavigationSettings(numbering: .allItems, cmd9: .last)
        let frames = sidebar.shortcutHintItemFrames
        return (1...min(8, model.itemOrder.items.count)).filter { digit in
            guard let item = model.itemOrder.pick(digit, settings) else { return true }
            return frames[item] == nil
        }
    }

    @Test func homeAndTheAppStoreInTheTopBlockHaveChips() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (model, sidebar, window) = Self.layOut([Self.topBlock()] + Self.machine([1, 2, 3]))
        defer { window.closeAfterTest() }
        let settings = SidebarNavigationSettings(numbering: .allItems, cmd9: .last)
        let home = SidebarItem.topItem(LayoutItemID("itm_home"))
        try #require(model.itemOrder.number(for: home, settings) == 1, "Home is not Cmd-1: \(model.itemOrder.items)")
        #expect(sidebar.shortcutHintItemFrames[home] != nil, "Home (Cmd-1) has no chip: \(sidebar.shortcutHintItemFrames.keys)")
        #expect(Self.digitsWithoutChip(model, sidebar).isEmpty,
                "digits without a chip: \(Self.digitsWithoutChip(model, sidebar)); order \(model.itemOrder.items)")
    }

    @Test func topItemsDrawnInTheBandHaveChips() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (model, sidebar, window) = Self.layOut(Self.machine([1, 2, 3]))
        defer { window.closeAfterTest() }
        try #require(!model.itemOrder.topItems.isEmpty, "no top items in the band: \(model.itemOrder.items)")
        #expect(Self.digitsWithoutChip(model, sidebar).isEmpty,
                "digits without a chip: \(Self.digitsWithoutChip(model, sidebar)); order \(model.itemOrder.items)")
    }

    /// Workspace rows keep their chips, keyed by the same item the digit selects.
    @Test func workspaceRowsStillHaveChips() {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (model, sidebar, window) = Self.layOut(Self.machine([1, 2, 3]))
        defer { window.closeAfterTest() }
        let rows = model.itemOrder.rows.filter { if case .workspace = $0 { true } else { false } }
        #expect(rows.count == 3)
        for row in rows { #expect(sidebar.shortcutHintItemFrames[row] != nil, "\(row) has no chip") }
    }
}
