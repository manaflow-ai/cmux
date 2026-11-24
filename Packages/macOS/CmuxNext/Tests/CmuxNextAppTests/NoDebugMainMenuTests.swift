import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The menu bar has no Debug menu, with Internal Developer Mode on or off: debug-only actions and the
/// old hand-built Debug items (Sidebar Toggle Icon, Status Icons, Main-Thread Blocking) are palette
/// rows only (`DebugActionsPaletteOnlyTests`).
@MainActor @Suite struct NoDebugMainMenuTests {
    private static func titles(in menu: NSMenu) -> [String] {
        menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) }
    }

    @Test(arguments: [false, true]) func theMenuBarHasNoDebugItem(on: Bool) {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        registry.debugActions = DebugActionGate(devTools: true, isOn: { on })
        let bar = MainMenu.make(registry: registry)
        #expect(!bar.items.contains { $0.title == "Debug" }, "top menus: \(bar.items.map(\.title))")
        let debugIDs = Set(ActionCatalog.all.filter(\.isDebugOnly).map(\.id.rawValue))
        let placed = Set(MainMenuPlacementTests.actionIDs(in: bar)).intersection(debugIDs)
        #expect(placed.isEmpty, "debug actions in the menu bar: \(placed.sorted())")
        let all = Self.titles(in: bar)
        for title in ["Sidebar Toggle Icon", "Status Icons"] { #expect(!all.contains(title), "\(title)") }
        #expect(!all.contains { $0.hasPrefix("Main-Thread Blocking") })
    }
}
