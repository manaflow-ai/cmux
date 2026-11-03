import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// Debug > Sidebar Toggle Icon and Debug > Status Icons belong to the menu bar item they make, not
/// to a process global: the item keeps its menu controller alive (an item's target and a menu's
/// delegate are weak), and two main menus with their own stores write only their own store.
@MainActor @Suite struct DebugIconMenusOwnerTests {
    private static func activeStore(_ descriptor: TunableDescriptor) -> TunableStore {
        let store = TunableStore()
        store.register([descriptor])
        store.activate(file: nil)
        return store
    }

    /// The controller's only reference is the one `makeItem()` leaves in the item.
    private static func sidebarItem(_ store: TunableStore) -> NSMenuItem { SidebarToggleIconMenu(store: store).makeItem() }
    private static func statusItem(_ store: TunableStore) -> NSMenuItem { StatusIconSetMenu(store: store).makeItem() }

    private static func choose(_ raw: String, in item: NSMenuItem) throws {
        let choice = try #require(item.submenu?.items.first { ($0.representedObject as? String) == raw })
        let target = try #require(choice.target as? NSObject, "the item keeps its menu controller alive")
        let action = try #require(choice.action)
        _ = target.perform(action, with: choice)
    }

    @Test func theSidebarToggleIconItemKeepsItsMenuAndWritesOnlyItsStore() throws {
        let icon = try #require(SidebarToggleIcon.allCases.first { $0 != SidebarToggleIcon.tunable.defaultValue })
        let mine = Self.activeStore(SidebarToggleIcon.tunable.descriptor), other = Self.activeStore(SidebarToggleIcon.tunable.descriptor)
        let item = Self.sidebarItem(mine)
        _ = Self.sidebarItem(other)
        #expect(item.submenu?.delegate != nil, "the submenu's delegate is alive")
        try Self.choose(icon.rawValue, in: item)
        #expect(SidebarToggleIcon.tunable.value(in: mine) == icon)
        #expect(SidebarToggleIcon.tunable.value(in: other) == SidebarToggleIcon.tunable.defaultValue, "another menu's store is untouched")
    }

    @Test func theStatusIconsItemKeepsItsMenuAndWritesOnlyItsStore() throws {
        let set = try #require(StatusIconSet.allCases.first { $0 != StatusIconSet.tunable.defaultValue })
        let mine = Self.activeStore(StatusIconSet.tunable.descriptor), other = Self.activeStore(StatusIconSet.tunable.descriptor)
        let item = Self.statusItem(mine)
        _ = Self.statusItem(other)
        #expect(item.submenu?.delegate != nil, "the submenu's delegate is alive")
        try Self.choose(set.rawValue, in: item)
        #expect(StatusIconSet.tunable.value(in: mine) == set)
        #expect(StatusIconSet.tunable.value(in: other) == StatusIconSet.tunable.defaultValue, "another menu's store is untouched")
    }
}
