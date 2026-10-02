import AppKit
import Testing
@testable import CmuxNextSidebar

/// The rail column's views: one icon button per laid-out item, the App's
/// tooltips, activation by item id, buttons removed when their items leave
/// or overflow, and one layer per section line.
@MainActor @Suite struct SidebarRailViewTests {
    private let m = SidebarRailMetrics(width: 48, buttonSize: 34, buttonGap: 4, sectionGap: 8, lineWidth: 1,
                                       lineInset: 12, topInset: 40, bottomInset: 12)

    private func rail(_ document: SidebarLayoutDocument, height: CGFloat = 600,
                      toolTips: [LayoutItemID: String] = [:]) -> SidebarRailView {
        let view = SidebarRailView()
        view.frame = NSRect(x: 0, y: 0, width: 48, height: height)
        view.update(.init(document: document, room: nil, infos: [:], toolTips: toolTips, metrics: m))
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func eachItemIsAnIconButtonAtItsLaidOutFrame() throws {
        let view = rail(.defaults)
        #expect(view.subviews.count == 4)
        for button in view.layoutResult.buttons {
            let item = try #require(view.itemView(button.item))
            #expect(item.frame == button.frame)
            #expect(item.style == .icon)
        }
    }

    /// The App's tooltip (title and shortcut) wins; without one the item's
    /// title shows.
    @Test func toolTipsComeFromTheAppElseTheTitle() throws {
        let home = LayoutItemID("itm_home")
        let view = rail(.defaults, toolTips: [home: "Home (⌘1)"])
        #expect(view.itemView(home)?.toolTip == "Home (⌘1)")
        #expect(view.itemView(LayoutItemID("itm_settings"))?.toolTip == SidebarBuiltIn.settings.title)
    }

    @Test func pressingAButtonActivatesItsItem() throws {
        let view = rail(.defaults)
        var activated: [LayoutItemID] = []
        view.onActivate = { activated.append($0) }
        try #require(view.itemView(LayoutItemID("itm_account"))).onPress?()
        #expect(activated == [LayoutItemID("itm_account")])
    }

    /// A removed item and an item that no longer fits lose their buttons.
    @Test func itemsThatLeaveOrOverflowLoseTheirButtons() throws {
        let view = rail(.defaults)
        var doc = SidebarLayoutDocument.defaults
        doc.sections[0].items.removeLast()
        view.update(.init(document: doc, room: nil, infos: [:], toolTips: [:], metrics: m))
        view.layoutSubtreeIfNeeded()
        #expect(view.itemView(LayoutItemID("itm_app_store")) == nil)
        #expect(view.subviews.count == 3)

        view.frame.size.height = 130
        view.layoutSubtreeIfNeeded()
        #expect(view.itemView(LayoutItemID("itm_home")) == nil)
        #expect(view.layoutResult.overflow == [LayoutItemID("itm_home")])
    }

    @Test func eachSectionLineIsALayer() {
        let doc = SidebarLayoutDocument(sections: [
            LayoutSection(id: LayoutSectionID("a"), region: .top, look: .builtIn,
                          items: [LayoutItem(id: LayoutItemID("a0"), ref: .builtIn(.home))]),
            LayoutSection(id: LayoutSectionID("b"), region: .top, look: .builtIn,
                          items: [LayoutItem(id: LayoutItemID("b0"), ref: .builtIn(.history))]),
            LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle, content: .workspaces),
        ])
        let view = rail(doc)
        let lines = view.layer?.sublayers?.filter { $0.frame == view.layoutResult.separators.first } ?? []
        #expect(view.layoutResult.separators.count == 1)
        #expect(lines.count == 1)
    }
}
