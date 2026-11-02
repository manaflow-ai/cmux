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
        let view = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 1, height: 30))
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
        view.layoutSubtreeIfNeeded()
        view.nativeOverflowItems().forEach { menu.addItem($0) }
        menu.update()
        let rows = menu.items
        try #require(rows.count == 4, "all four native tools must overflow before indexing menu rows")
        let disabled = rows[0]
        #expect(!disabled.isEnabled)
        let disabledMenu = rows[1]
        let disabledChild = try #require(disabledMenu.submenu?.items.first)
        #expect(!disabledMenu.isEnabled)
        #expect(!disabledChild.isEnabled)
        let nestedParent = try #require(rows[2].submenu?.items.first)
        let nestedChild = try #require(nestedParent.submenu?.items.first)
        #expect(!nestedParent.isEnabled)
        #expect(!nestedChild.isEnabled)
        for row in [disabled, disabledMenu, disabledChild, nestedParent, nestedChild] {
            let action = try #require(row.action)
            // A direct selector dispatch must not bypass menu validation or disabled ancestors.
            #expect(NSApplication.shared.sendAction(action, to: row.target, from: row))
        }
        #expect(invoked.isEmpty)
        let enabled = rows[3]
        #expect(enabled.isEnabled)
        #expect(NSApplication.shared.sendAction(try #require(enabled.action), to: enabled.target, from: enabled))
        #expect(invoked == ["enabled"])
    }

    @Test func retainedOverflowRowsCannotInvokeReplacedTools() throws {
        let view = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 1, height: 30))
        view.show(more: true, lit: false, nativeItems: [
            PaneTabRowTool(id: "review", symbol: "checkmark", label: "Review"),
        ])
        view.layoutSubtreeIfNeeded()
        var invoked = false
        view.onNativeTool = { _, _ in invoked = true }
        let row = try #require(view.nativeOverflowItems().first)
        view.show(more: true, lit: false, nativeItems: [
            PaneTabRowTool(id: "review", symbol: "checkmark", label: "Review", enabled: false),
        ])
        view.layoutSubtreeIfNeeded()
        let menu = NSMenu()
        menu.addItem(row)
        menu.update()
        #expect(!row.isEnabled)
        #expect(NSApplication.shared.sendAction(try #require(row.action), to: row.target, from: row))
        #expect(!invoked)
    }

    /// "…" lists only the native tools whose buttons do not fit: a tool that shows is not listed twice.
    @Test func overflowListsOnlyNativeToolsThatDoNotFit() {
        let tools = ["review", "share"].map { PaneTabRowTool(id: $0, symbol: "checkmark", label: $0) }
        let wide = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        wide.show(more: true, lit: false, nativeItems: tools)
        wide.layoutSubtreeIfNeeded()
        #expect(wide.nativeButtons.allSatisfy { !$0.isHidden })
        #expect(wide.nativeOverflowItems().isEmpty, "visible native tools are duplicated under …")

        let narrow = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 1, height: 30))
        narrow.show(more: true, lit: false, nativeItems: tools)
        narrow.layoutSubtreeIfNeeded()
        let hidden = zip(tools, narrow.nativeButtons).filter { $0.1.isHidden }.map(\.0.label)
        #expect(!hidden.isEmpty)
        #expect(narrow.nativeOverflowItems().map(\.title) == hidden)

    }

    @Test func narrowToolbarHidesPartialNativeSlotWithoutOverlappingMore() {
        DensityTokens.$scoped.withValue(DensityPreset.compact.tokens) {
            let tools = [
                PaneTabRowTool(id: "first", symbol: "checkmark", label: "First"),
                PaneTabRowTool(id: "second", symbol: "square", label: "Second"),
            ]
            let view = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 60, height: 30))
            view.show(more: true, lit: false, nativeItems: tools)
            view.layoutSubtreeIfNeeded()

            let visible = view.nativeButtons.filter { !$0.isHidden } + [view.moreButton]
            for (index, button) in visible.enumerated() {
                for other in visible.dropFirst(index + 1) {
                    #expect(!button.frame.intersects(other.frame), "visible native controls must not overlap")
                }
            }
            let hidden = zip(tools, view.nativeButtons).filter { $0.1.isHidden }.map(\.0.label)
            #expect(!hidden.isEmpty, "a partial slot must move to overflow")
            #expect(view.nativeOverflowItems().map(\.title) == hidden)
        }
    }

    @Test func textToolGetsAWiderSlotAndIconOnlyToolsKeepTheirSlot() {
        let icon = PaneTabRowTool(id: "icon", symbol: "checkmark", label: "Icon")
        let text = PaneTabRowTool(id: "text", symbol: "checkmark", label: "Text", text: "#123 ✓3/5")
        let view = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        view.show(more: false, lit: false, nativeItems: [icon, text])
        view.layoutSubtreeIfNeeded()
        #expect(view.nativeButtons[0].frame.width == TitlebarBandButton.side)
        #expect(view.nativeButtons[1].frame.width > view.nativeButtons[0].frame.width)
        #expect(view.nativeOverflowItems().isEmpty)
    }

    @Test func iconAndOverflowFitAtTheirIntrinsicWidth() {
        let icon = PaneTabRowTool(id: "icon", symbol: "checkmark", label: "Icon")
        let view = PaneToolbarView(frame: .zero)
        view.show(more: true, lit: false, nativeItems: [icon])
        let width = view.intrinsicContentSize.width
        view.frame.size.width = width
        view.layoutSubtreeIfNeeded()
        #expect(view.nativeButtons.first?.isHidden == false)
        #expect(view.nativeOverflowItems().isEmpty)
    }

    @Test func menuURLOpensOnceAndStaleOwnerCannotInvokeIt() throws {
        let url = "https://example.com/pull/123"
        let item = PaneTabRowMenuItem(id: "open", label: "Open", url: url)
        let tool = PaneTabRowTool(id: "review", symbol: "checkmark", label: "Review", menu: [item])
        let view = PaneToolbarView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        view.show(more: false, lit: false, nativeItems: [tool])
        var owner = "first"
        var opened: [URL] = []
        var invoked: [(String, String?)] = []
        view.openURL = { opened.append($0) }
        view.onNativeToolURL = { id, menuID, openedURL in
            guard owner == "first" else { return }
            view.openURL(openedURL)
            invoked.append((id, menuID))
        }
        let menu = try #require(view.nativeButtons.first?.pressMenu?())
        let row = try #require(menu.items.first)
        #expect(NSApplication.shared.sendAction(try #require(row.action), to: row.target, from: row))
        #expect(opened == [try #require(URL(string: url))])
        #expect(invoked.map { [$0.0, $0.1 ?? ""] } == [["review", "open"]])

        owner = "second"
        view.show(more: false, lit: false,
                  nativeItems: [tool])
        #expect(NSApplication.shared.sendAction(try #require(row.action), to: row.target, from: row))
        #expect(opened.count == 1)
        #expect(invoked.count == 1)
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
