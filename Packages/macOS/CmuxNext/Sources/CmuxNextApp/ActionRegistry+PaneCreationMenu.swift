import AppKit
import CmuxNextActions
import CmuxNextDesign

extension ActionRegistry {
    /// Pane creation and the full command catalog share the visible + menu.
    func makePaneCreationMenu(target: ActionTargetRef) -> NSMenu {
        let entries = ContextMenuCatalog.shared.entries(for: .newTab) + [.separator, .action("commandPalette")]
        let menu = makeContextMenu(for: .newTab, target: target, entries: entries)
        if let commands = menu.items.last, Self.menuRun(of: commands)?.id == "commandPalette",
           let symbol = descriptor(for: "commandPalette")?.symbol {
            // The catalog treats the default command symbol as no icon; this discovery row names it explicitly.
            commands.title = String(localized: "paneCreation.allCommands", defaultValue: "All commands…", table: "PaneCreation", bundle: .module)
            commands.image = .menuSymbol(symbol)
        }
        return menu
    }
}
