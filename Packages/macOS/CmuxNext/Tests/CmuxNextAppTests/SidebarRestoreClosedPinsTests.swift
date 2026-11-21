import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// https://github.com/manaflow-ai/cmux/issues/42372: after a restore the sidebar filled with ~30 pinned rows, each titled
/// `5a73805b-4338-4e9d-a123-…`. Pinned keeps a closed workspace's item (`keeps_closed`), and the restored document had 65
/// of them with no stored name. On a snapshot-first launch the band draws the document before the App has supplied any
/// item info, so each of those items drew `SidebarItemInfo.fallback(for:)`: its raw reference `<session>:<ws_…>`,
/// which truncates to the same session UUID on every row, and nothing hid it. A workspace item the App has not described
/// is a closed (or not yet known) workspace: it draws under its stored name, or not at all; never as its reference.
@MainActor
struct SidebarRestoreClosedPinsTests {
    static let session = "5a73805b-4338-4e9d-a123-15c110317cfc"
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)
    /// The one pinned workspace that is open again after the restore (the App describes it).
    static let live = LayoutItem(id: LayoutItemID("itm_live"), ref: .workspace("\(session):ws_live"))
    /// A closed pin that stored its name (an old tile's label).
    static let named = LayoutItem(id: LayoutItemID("itm_named"), ref: .workspace("\(session):ws_named"), label: "Closed but named")
    /// Closed pins with no stored name, as the report's document held them.
    static let unnamed = (0..<30).map { LayoutItem(id: LayoutItemID("itm_closed_\($0)"), ref: .workspace("\(session):ws_closed_\($0)")) }

    static let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
    static let pinned = SidebarLayoutDocument.pinnedSection(items: [live, named] + unnamed)

    static func sidebar(infos: [LayoutItemID: SidebarItemInfo]) -> (SidebarModel, SidebarView) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
            SidebarSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("ws_live"), title: "Live pin"))]),
        ], activeWorkspaceID: nil)
        model.layout = SidebarLayoutDocument(sections: [top, pinned])
        model.itemInfo = infos
        model.docDrag = SidebarDocDrag(item: { _ in nil }, section: { _ in nil }, begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { _ in nil })
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        sidebar.renderNow()
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        return (model, sidebar)
    }

    static func view(_ id: LayoutItemID, in sidebar: SidebarView) -> SidebarItemRowView? {
        sidebar.list.blockRegions.lazy.compactMap { $0.itemView(id) }.first
    }

    static func drawnTitles(_ sidebar: SidebarView) -> [String] {
        sidebar.list.blockRegions.flatMap { $0.itemViews.values.map(\.titleText) }
    }

    static var liveInfo: SidebarItemInfo {
        var info = SidebarItemInfo(title: "Live pin", symbol: "textformat")
        info.workspace = WorkspaceID("ws_live")
        return info
    }

    /// The restore's first frames: the document is drawn, the App's item info is not in yet (Home only).
    @Test func beforeTheAppDescribesThemClosedPinsNeverDrawTheirReference() throws {
        let (_, sidebar) = Self.sidebar(infos: [Self.home.id: SidebarItemInfo(title: "Home", symbol: "house")])
        try #require(Self.view(Self.home.id, in: sidebar) != nil, "the fixture drew no top block")
        let raw = Self.drawnTitles(sidebar).filter { $0.hasPrefix(Self.session) }
        #expect(raw.isEmpty, "\(raw.count) pinned rows drew a raw workspace reference: \(raw.prefix(3))")
        for item in Self.unnamed { #expect(Self.view(item.id, in: sidebar) == nil, "\(item.id.rawValue) drew a row with no name") }
        #expect(Self.view(Self.named.id, in: sidebar)?.titleText == "Closed but named")
    }

    /// The App's pass: the open pin is described, the closed ones are not (they have no open workspace).
    @Test func afterTheAppDescribesTheOpenPinOnlyNamedRowsDraw() throws {
        let (_, sidebar) = Self.sidebar(infos: [Self.home.id: SidebarItemInfo(title: "Home", symbol: "house"), Self.live.id: Self.liveInfo])
        #expect(Self.view(Self.live.id, in: sidebar)?.titleText == "Live pin")
        #expect(Self.view(Self.named.id, in: sidebar)?.titleText == "Closed but named")
        let raw = Self.drawnTitles(sidebar).filter { $0.hasPrefix(Self.session) }
        #expect(raw.isEmpty, "\(raw.count) pinned rows drew a raw workspace reference")
        let drawnPins = Self.pinned.items.filter { Self.view($0.id, in: sidebar) != nil }
        #expect(drawnPins.map(\.id) == [Self.live.id, Self.named.id], "Pinned drew \(drawnPins.count) rows, not the open one and the named one")
    }

    /// Cmd-1…9 stops: a closed pin with no name draws nothing, so it is no stop either.
    @Test func closedPinsWithNoNameAreNoStops() {
        let (model, _) = Self.sidebar(infos: [Self.home.id: SidebarItemInfo(title: "Home", symbol: "house"), Self.live.id: Self.liveInfo])
        // Pinned draws as a list block: its items are stops among the rows (`itemOrder.items`), not top items.
        let stops = model.itemOrder.items
        for item in Self.unnamed { #expect(!stops.contains(.topItem(item.id)), "\(item.id.rawValue) is a stop") }
        #expect(stops.contains(.topItem(Self.live.id)), "the open pin is no stop: \(stops)")
    }
}
