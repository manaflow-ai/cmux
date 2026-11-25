import AppKit
@testable import CmuxNextActions
import Testing

/// A right-click row that says why it is disabled draws that reason as its subtitle, which AppKit lays
/// under the shortcut column: "Close Other Tabs" drew ⌥⌘T over "Pinned tabs stay open." (Leo
/// 2026-11-07). The rule, at any depth of any menu: a row shows a reason or a shortcut, never both.
@MainActor
struct ContextMenuReasonShortcutTests {
    static let noOthers = "There are no other tabs to close. Pinned tabs stay open."

    /// Every row of `menu`, submenus included.
    private func rows(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(rows) ?? []) }
    }

    private func overlapping(_ menu: NSMenu) -> [String] {
        rows(menu).filter { $0.toolTip != nil && !$0.keyEquivalent.isEmpty }.map(\.title)
    }

    @Test func aDisabledTabRowShowsItsReasonWithoutItsShortcut() throws {
        let registry = ActionRegistry.standard()
        registry.bind("closeOtherTabsInPane", invoke: { _ in })
        ActionTargetReasons.set("closeOtherTabsInPane", in: registry) { _ in Self.noOthers }
        let menu = registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: "t"))
        let row = try #require(rows(menu).first { $0.identifier?.rawValue == "cmux.action.closeOtherTabsInPane" })
        #expect(row.toolTip == Self.noOthers)
        if #available(macOS 14.4, *) { #expect(row.subtitle == Self.noOthers) }
        #expect(row.keyEquivalent.isEmpty)
        #expect(row.keyEquivalentModifierMask.isEmpty)
        #expect(overlapping(menu).isEmpty, "rows drawing a reason through their shortcut: \(overlapping(menu))")
    }

    /// The same row with no reason keeps its shortcut.
    @Test func anEnabledTabRowKeepsItsShortcut() throws {
        let registry = ActionRegistry.standard()
        registry.bind("closeOtherTabsInPane", invoke: { _ in })
        let menu = registry.makeContextMenu(for: .tab, target: ActionTargetRef(kind: .tab, id: "t"))
        let row = try #require(rows(menu).first { $0.identifier?.rawValue == "cmux.action.closeOtherTabsInPane" })
        #expect(row.toolTip == nil)
        #expect(row.keyEquivalent == "t")
        #expect(row.keyEquivalentModifierMask == [.option, .command])
    }

    /// A configured row (a workspace group's `contextMenu`) goes through the same decoration.
    @Test func aConfiguredRowWithAReasonDropsItsShortcut() throws {
        let registry = ActionRegistry.standard()
        registry.bind("closeOtherTabsInPane", invoke: { _ in })
        ActionTargetReasons.set("closeOtherTabsInPane", in: registry) { _ in Self.noOthers }
        let row = try #require(registry.makeConfiguredContextItem(for: "closeOtherTabsInPane",
                                                                  target: ActionTargetRef(kind: .tab, id: "t"), title: nil))
        #expect(row.toolTip == Self.noOthers)
        #expect(row.keyEquivalent.isEmpty)
    }

    /// A row whose click recovers first (Sign In, then the action) shows that note, so it drops its shortcut too.
    @Test func aRecoveryNoteRowDropsItsShortcut() {
        let (registry, _, _) = ActionRecoveryTests.signedOut()
        let item = NSMenuItem(title: "Open Desktop", action: nil, keyEquivalent: "o")
        item.keyEquivalentModifierMask = [.command]
        ActionTargetTitles.decorate(item, id: ActionRecoveryTests.id, invocation: ActionInvocation(), in: registry)
        #expect(item.toolTip == "signs in first")
        #expect(item.keyEquivalent.isEmpty)
    }
}
