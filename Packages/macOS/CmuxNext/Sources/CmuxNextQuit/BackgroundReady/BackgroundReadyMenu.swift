import AppKit
import CmuxNextActions

/// Quit Completely in the app menu: Quit's Option-alternate (Option-Cmd-Q), there only while
/// `app.backgroundReady` is on. The menu is built once at launch (`MainMenu`); this adds the row after
/// Quit and takes it out again as the setting changes.
@MainActor
enum BackgroundReadyMenu {
    private static let quitID = NSUserInterfaceItemIdentifier("cmux.action.quit")
    private static let completelyID = NSUserInterfaceItemIdentifier("cmux.action.quitCompletely")

    static func place(registry: ActionRegistry, shown: Bool) {
        guard let menu = NSApp.mainMenu?.items.first?.submenu else { return }
        let placed = menu.items.first { $0.identifier == completelyID }
        guard shown else {
            if let placed { menu.removeItem(placed) }
            return
        }
        guard placed == nil, let quit = menu.items.firstIndex(where: { $0.identifier == quitID }),
              let item = registry.makeMenuItem(for: "quitCompletely") else { return }
        item.keyEquivalent = "q"
        item.keyEquivalentModifierMask = [.command, .option]
        item.isAlternate = true
        menu.insertItem(item, at: quit + 1)
    }
}
