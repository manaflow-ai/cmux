import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextApps
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The sidebar's edit mode (Leo 2026-10-20, as an iPhone's home screen): Edit Sidebar makes its items
/// wiggle (through the sidebar's motion gate: still under Reduce Motion), a drag moves one, its ✕
/// takes it out (the menu's Remove), a press opens nothing, Add Items opens App Store Features on
/// Sidebar, where the built-in items are cards, and Done ends it.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarEditModeTests {
    static let link = LayoutItemID("itm_link"), app = LayoutItemID("itm_app")

    final class Band {
        let region = SidebarRegionView(region: .top)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        var activated: [LayoutItemID] = [], removed: [LayoutItemID] = []

        init() {
            let items = [LayoutItem(id: SidebarEditModeTests.link, ref: .url("https://example.com")),
                         LayoutItem(id: SidebarEditModeTests.app, ref: .app("acme/notes"))]
            let section = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, items: items)
            let content = SidebarRegionView.Content(sections: [section], infos: [:], collapsed: [], look: SidebarSectionTunables.currentLook,
                                                    metrics: .standard, drawsLines: false)
            region.onActivate = { [unowned self] in activated.append($0) }
            region.onRemoveItem = { [unowned self] in removed.append($0) }
            region.frame = NSRect(x: 0, y: 0, width: 240, height: 360)
            region.update(content, width: 240)
            window.contentView = region
            window.orderFrontRegardless()
            region.layoutSubtreeIfNeeded()
        }

        func view(_ id: LayoutItemID) throws -> SidebarItemRowView {
            let view = try #require(region.itemView(id), "the band draws no \(id.rawValue) item")
            view.layoutSubtreeIfNeeded()
            return view
        }

        func event(_ type: NSEvent.EventType, on view: NSView) throws -> NSEvent {
            let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            return try #require(NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                   pressure: type == .leftMouseUp ? 0 : 1))
        }

        func click(_ view: NSView) throws {
            view.mouseDown(with: try event(.leftMouseDown, on: view))
            view.mouseUp(with: try event(.leftMouseUp, on: view))
        }
    }

    @Test func inEditModeAnItemShowsItsXAndAPressOpensNothing() throws {
        let band = Band()
        defer { band.window.closeAfterTest() }
        try band.click(try band.view(Self.link))
        #expect(band.activated == [Self.link], "the fixture's press did not open the item")

        band.region.isEditing = true
        let link = try band.view(Self.link)
        let app = try band.view(Self.app)
        #expect(link.isEditing && app.isEditing)
        try band.click(link)
        #expect(band.activated == [Self.link], "a press in edit mode opened the item")
        let x = try #require(link.removeButton, "an edited item has no ✕")
        #expect(x.label.hasPrefix("Remove "), "the ✕ does not name what it removes: \(x.label)")
        x.onPress?()
        #expect(band.removed == [Self.link])

        band.region.isEditing = false
        #expect(!link.isEditing && link.removeButton == nil)
        try band.click(link)
        #expect(band.activated == [Self.link, Self.link], "out of edit mode a press opens the item again")
    }

    @Test func theWiggleGoesThroughTheMotionGate() throws {
        defer { Motion.reduceMotionOverride = nil }
        Motion.reduceMotionOverride = false
        #expect(Motion.sidebar.wiggleAnimation(center: .zero) != nil)
        let band = Band()
        defer { band.window.closeAfterTest() }
        band.region.isEditing = true
        let link = try band.view(Self.link)
        #expect(link.layer?.animation(forKey: SidebarItemRowView.wiggleKey) != nil, "an edited item does not wiggle")
        band.region.isEditing = false
        link.layoutSubtreeIfNeeded()
        #expect(link.layer?.animation(forKey: SidebarItemRowView.wiggleKey) == nil, "the wiggle outlived edit mode")

        // Reduce Motion: edit mode still works, and nothing moves.
        Motion.reduceMotionOverride = true
        #expect(Motion.sidebar.wiggleAnimation(center: .zero) == nil)
        band.region.isEditing = true
        let still = try band.view(Self.link)
        #expect(still.removeButton != nil)
        #expect(still.layer?.animation(forKey: SidebarItemRowView.wiggleKey) == nil, "an item wiggles under Reduce Motion")
    }

    @Test func editSidebarShowsTheBarAndDoneEndsIt() throws {
        let model = SidebarModel(sections: [])
        var intents: [SidebarIntent] = []
        model.onIntent = { intents.append($0) }
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()

        sidebar.setEditingItems(true)
        sidebar.layoutSubtreeIfNeeded()
        let bar = try #require(sidebar.editBar)
        #expect(bar.superview === sidebar && bar.frame.width > 0)
        let regions = sidebar.bandRegions + sidebar.list.blockRegions
        #expect(regions.allSatisfy { $0.isEditing == ($0 !== sidebar.footerRegion) }, "the footer is edited, or an item band is not")
        bar.add.performClick(nil)
        #expect(intents == [.addItems])
        bar.done.performClick(nil)
        #expect(!sidebar.isEditingItems && sidebar.editBar == nil)
        #expect(!regions.contains { $0.isEditing })
    }

    /// Escape on a focused item ends edit mode (Done has no keycap: a focused pane keeps Escape).
    @Test func escapeOnAnEditedItemEndsEditMode() throws {
        let sidebar = SidebarView(model: SidebarModel(sections: []), design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.setEditingItems(true)
        sidebar.layoutSubtreeIfNeeded()
        let item = try #require((sidebar.aboveRegion.itemViews.values.first ?? sidebar.belowRegion.itemViews.values.first),
                                "the default sidebar draws no item in its bands")
        #expect(item.isEditing)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        item.keyDown(with: escape)
        #expect(!sidebar.isEditingItems && !item.isEditing)
    }

    @Test func editSidebarIsOnTheSidebarsMenusAndThePalette() throws {
        let edit = try #require(ActionCatalog.all.first { $0.id == "sidebar.edit" })
        #expect(edit.surfaces.contains(.palette) && edit.surfaces.contains(.contextMenu))
        #expect(edit.title == "Edit Sidebar")
    }

    /// Add Items' cards: Home, Notifications, History, Bookmarks and the launchers (Search Chats, New
    /// Terminal, New Browser Tab, New Agent Chat, Customize, Automations) beside the Chief's, each on when the
    /// sidebar shows it (Home as the app it is now), Get and Remove the sidebar's own actions.
    @Test func theSidebarCategoryListsTheBuiltInItems() {
        let builtIns: Set<String> = ["home", "notifications", "history", "bookmarks", "search_chats", "new_terminal", "new_browser",
                                     "new_agent_chat", "customize", "automations"]
        let items = AppFeature.catalog.filter { $0.category == .sidebar }.compactMap(\.sidebarItem)
        #expect(Set(items) == builtIns)

        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        var runs: [String] = []
        registry.bind("sidebar.item.add", invoke: { runs.append("add \($0["item"]?.stringValue ?? "")") })
        registry.bind("sidebar.item.removeEverywhere", invoke: { runs.append("remove \($0.target?.id ?? "")") })
        let chief = SettingsAppFeatures.SidebarItems(names: ["chief"], isShown: { _ in true }, set: { _, _ in runs.append("chief"); return true })
        let store = SidebarSectionHandlers.storeItems(chief: chief, document: { .defaults }, registry: registry)
        #expect(store.names == builtIns.union(["chief"]))
        #expect(store.isShown("home"), "the default sidebar's Home (an app item) reads as off")
        #expect(!store.isShown("bookmarks"))
        #expect(!store.isShown("automations"), "Automations stays opt-in in the default layout")
        #expect(store.isShown("chief"), "the Chief's own answer was lost")
        _ = store.set("bookmarks", true)
        _ = store.set("history", false)
        _ = store.set("chief", true)
        #expect(runs == ["add bookmarks", "remove history", "chief"])
    }
}
