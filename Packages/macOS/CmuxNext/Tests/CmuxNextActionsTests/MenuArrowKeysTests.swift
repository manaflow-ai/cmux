import AppKit
import CmuxNextActions
import Testing

/// `debug.object_menu`'s `choose` (What's New clip `customizations-menu`): the Down arrows it posts land on the row
/// named, passing over what the keyboard never highlights, such as the Experiments and Labs section headers of
/// cmux > Customizations.
@MainActor @Suite
struct MenuArrowKeysTests {
    #if DEBUG
    static func customizationsLike() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Experiments"))
        menu.addItem(NSMenuItem(title: "Agent Badges", action: nil, keyEquivalent: ""))
        let managed = NSMenuItem(title: "Managed", action: nil, keyEquivalent: "")
        managed.isEnabled = false
        menu.addItem(managed)
        menu.addItem(.sectionHeader(title: "Labs"))
        menu.addItem(NSMenuItem(title: "Live Code", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "All Customizations…", action: nil, keyEquivalent: ""))
        return menu
    }

    @Test func chooseSkipsSectionHeaders() {
        let menu = Self.customizationsLike()
        #expect(MenuArrowKeys.codes([], choose: "Agent Badges", in: menu) == [125, 36])
        #expect(MenuArrowKeys.codes([], choose: "Live Code", in: menu) == [125, 125, 36])
        #expect(MenuArrowKeys.codes([], choose: "All Customizations…", in: menu) == [125, 125, 125, 36])
    }

    @Test func chooseRefusesDisabledAndMissingRows() {
        let menu = Self.customizationsLike()
        #expect(MenuArrowKeys.codes([], choose: "Managed", in: menu) == nil)
        #expect(MenuArrowKeys.codes([], choose: "Labs", in: menu) == nil)
    }
    #endif
}
