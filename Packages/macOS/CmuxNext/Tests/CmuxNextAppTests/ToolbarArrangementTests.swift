import CmuxNextActions
import Foundation
import Testing
@testable import CmuxNextApp

/// R69 toolbar band catalog (titlebar-area.md 3, app-platform.md 17): every
/// item is a catalog entry; the user hides, reorders and rebinds items in
/// `toolbar.items`; the sidebar toggle stays first and cannot be hidden; at
/// most three app items show, the rest go to the overflow menu; an app's
/// `overrides` item applies only when the user picks it.
@Suite struct ToolbarArrangementTests {
    static func app(_ id: String, order: Int? = nil, overrides: String? = nil) -> ToolbarEntry {
        ToolbarEntry(id: "app:mail/\(id)", action: ActionID(rawValue: "mail.\(id)"), symbol: "envelope", title: id, appID: "mail",
                     order: order, overrides: overrides)
    }

    @Test func defaultsAreTheBuiltInsThenThreeAppItemsAndTheRestOverflow() {
        let apps = [Self.app("d", order: 40), Self.app("a", order: 10), Self.app("c", order: 30), Self.app("b", order: 20)]
        let result = ToolbarArrangement.arrange(apps: apps, preference: [])
        #expect(result.visible.map(\.id) == ["sidebar.toggle", "nav.back", "nav.forward", "app:mail/a", "app:mail/b", "app:mail/c"])
        #expect(result.overflow.map(\.id) == ["app:mail/d"])
    }

    @Test func theUserReordersHidesAndRebindsButTheToggleStaysFirst() {
        let preference = [ToolbarItemPreference(id: "nav.forward"),
                          ToolbarItemPreference(id: "sidebar.toggle", hidden: true),
                          ToolbarItemPreference(id: "nav.back", action: "goToWorkspace")]
        let result = ToolbarArrangement.arrange(apps: [], preference: preference)
        #expect(result.visible.map(\.id) == ["sidebar.toggle", "nav.forward", "nav.back"])
        #expect(result.visible.first { $0.id == "nav.back" }?.action == "goToWorkspace")
        let hidden = ToolbarArrangement.arrange(apps: [], preference: [ToolbarItemPreference(id: "nav.back", hidden: true)])
        #expect(hidden.visible.map(\.id) == ["sidebar.toggle", "nav.forward"])
    }

    @Test func anOverrideAppliesOnlyWhenTheUserPicksIt() {
        let back = Self.app("back", overrides: "nav.back")
        let silent = ToolbarArrangement.arrange(apps: [back], preference: [])
        #expect(silent.visible.map(\.id) == ["sidebar.toggle", "nav.back", "nav.forward"])
        #expect(silent.visible[1].action == "focusHistoryBack")
        let picked = ToolbarArrangement.arrange(apps: [back], preference: [ToolbarItemPreference(id: "nav.back", use: "app:mail/back")])
        #expect(picked.visible.map(\.id) == ["sidebar.toggle", "nav.back", "nav.forward"])
        #expect(picked.visible[1].action == "mail.back" && picked.visible[1].title == "back")
    }

    @Test func hiddenAppItemsFreeAVisibleSlot() {
        let apps = (1...4).map { (n: Int) in Self.app("i\(n)", order: n) }
        let result = ToolbarArrangement.arrange(apps: apps, preference: [ToolbarItemPreference(id: "app:mail/i2", hidden: true)])
        #expect(result.visible.suffix(3).map(\.id) == ["app:mail/i1", "app:mail/i3", "app:mail/i4"])
        #expect(result.overflow.isEmpty)
    }
}
