import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// The pane toolbar's more button is the app's one overflow button (⋮, Leo 2026-10-20, #22972):
/// a pointer press opens its menu on mouse-down, and VoiceOver's press opens the same menu. Its menu
/// is a standard macOS menu, like every right-click menu.
@MainActor @Suite struct PaneMoreOverflowButtonTests {
    @Test func voiceOversPressOpensThePanesMenu() {
        let view = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        view.show(more: true, lit: false)
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename Tab", action: nil, keyEquivalent: "")
        view.moreMenu = { menu }
        var shown: NSMenu?
        view.moreButton.presentMenu = { menu, _ in shown = menu }
        #expect(view.moreButton.accessibilityPerformPress())
        #expect(shown === menu)
        #expect(view.moreButton.accessibilityLabel() == view.moreButton.label)
    }

    @Test func nativeToolKeyboardActivationOpensItsMenu() throws {
        let view = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let tool = PaneTabRowTool(id: "review", symbol: "checkmark", label: "Review",
                                  menu: [PaneTabRowMenuItem(id: "open", label: "Open")])
        view.show(more: false, lit: false, nativeItems: [tool])
        var invoked: [String] = []
        view.onNativeTool = { id, _ in invoked.append(id) }
        let button = try #require(view.nativeButtons.first)
        var shown: NSMenu?
        button.presentMenu = { menu, _ in shown = menu }
        // Space sends the button's target/action; it must open the same menu as a pointer press.
        #expect(button.sendAction(button.action, to: button.target))
        #expect(shown?.items.map(\.title) == ["Open"])
        #expect(invoked.isEmpty)
        let row = try #require(shown?.items.first)
        let action = try #require(row.action)
        #expect(NSApplication.shared.sendAction(action, to: row.target, from: row))
        #expect(invoked == ["review"])
    }

    @Test func overflowValidationPreservesDisabledToolsAndAncestors() throws {
        let view = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        let child = PaneTabRowMenuItem(id: "child", label: "Child")
        view.show(more: true, lit: false, nativeItems: [
            PaneTabRowTool(id: "disabled", symbol: "checkmark", label: "Disabled", enabled: false),
            PaneTabRowTool(id: "disabled-menu", symbol: "checkmark", label: "Disabled menu", enabled: false, menu: [child]),
            PaneTabRowTool(id: "menu", symbol: "checkmark", label: "Menu", menu: [
                PaneTabRowMenuItem(id: "parent", label: "Parent", enabled: false, children: [child]),
            ]),
            PaneTabRowTool(id: "enabled", symbol: "checkmark", label: "Enabled"),
        ])
        var invoked: [String] = []
        view.onNativeTool = { id, _ in invoked.append(id) }
        let menu = NSMenu()
        // Registry-built overflow menus enable this; AppKit must still honor page declarations.
        menu.autoenablesItems = true
        view.nativeOverflowItems().forEach { menu.addItem($0) }
        menu.update()
        let disabled = try #require(menu.item(at: 0))
        #expect(!disabled.isEnabled)
        let disabledMenu = try #require(menu.item(at: 1))
        let disabledChild = try #require(disabledMenu.submenu?.items.first)
        #expect(!disabledMenu.isEnabled)
        #expect(!disabledChild.isEnabled)
        let nestedParent = try #require(menu.item(at: 2)?.submenu?.items.first)
        let nestedChild = try #require(nestedParent.submenu?.items.first)
        #expect(!nestedParent.isEnabled)
        #expect(!nestedChild.isEnabled)
        for row in [disabled, disabledMenu, disabledChild, nestedParent, nestedChild] {
            let action = try #require(row.action)
            // A direct selector dispatch must not bypass menu validation or disabled ancestors.
            #expect(NSApplication.shared.sendAction(action, to: row.target, from: row))
        }
        #expect(invoked.isEmpty)
        let enabled = try #require(menu.item(at: 3))
        #expect(enabled.isEnabled)
        #expect(NSApplication.shared.sendAction(try #require(enabled.action), to: enabled.target, from: enabled))
        #expect(invoked == ["enabled"])
    }

    @Test func retainedOverflowRowsCannotInvokeReplacedTools() throws {
        let view = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        view.show(more: true, lit: false, nativeItems: [
            PaneTabRowTool(id: "review", symbol: "checkmark", label: "Review"),
        ])
        let row = try #require(view.nativeOverflowItems().first)
        var invoked = false
        view.onNativeTool = { _, _ in invoked = true }
        view.show(more: true, lit: false, nativeItems: [
            PaneTabRowTool(id: "review", symbol: "checkmark", label: "Review", enabled: false),
        ])
        let menu = NSMenu()
        menu.addItem(row)
        menu.update()
        #expect(!row.isEnabled)
        #expect(NSApplication.shared.sendAction(try #require(row.action), to: row.target, from: row))
        #expect(!invoked)
    }

    @Test func aLitMenuDrawsInTheAccent() {
        let view = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        view.show(more: true, lit: true)
        #expect(view.moreButton.tintOverride != nil)
        view.show(more: true, lit: false)
        #expect(view.moreButton.tintOverride == nil)
    }

    /// The menu starts with the New Tab rows and adds the tab's actions, Search Tabs and Show in Tab
    /// Bar: every one a standard macOS row.
    @Test func everyRowOfTheMenuIsNative() throws {
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        toolbar.update(target: "tab0", kind: .terminal)
        let menu = try #require(toolbar.view.moreMenu?())
        let rows = menu.items.filter { !$0.isSeparatorItem }
        #expect(!rows.isEmpty)
        for item in rows {
            #expect(item.view == nil, "\(item.title) is custom-drawn, not a standard macOS row")
        }
    }
}
