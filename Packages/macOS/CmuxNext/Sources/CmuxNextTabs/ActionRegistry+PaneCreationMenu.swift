public import AppKit
public import CmuxNextActions
import CmuxNextDesign
public import CmuxNextSettings
import CmuxNextWindowRules

extension ActionRegistry {
    /// Only the primary + uses this ordered list. Resolve it on the gesture so settings reloads
    /// need no per-pane observer. The existing runners retain their permissions and refusals.
    public func makeConfiguredPlusMenu(root: JSONValue, target: ActionTargetRef, machineID: String?, localMachineID: String) -> NSMenu? {
        let rows = WindowRules().plusMenu(root.value(at: CmuxConfigSnapshot.plusMenuPath) ?? .null)
        guard !rows.isEmpty else { return nil }
        let menu = NSMenu()
        for row in rows {
            let arguments: [String: ActionValue] = row.localWorkspace ? ["machine": .string(localMachineID)] : [:]
            let items = makeContextMenu(for: .newTab, target: row.paneTarget ? target : nil,
                                        entries: [.action(ActionID(rawValue: row.action))], arguments: arguments,
                                        customize: false, machineID: row.localWorkspace ? localMachineID : machineID)
            let detached = items.items
            items.removeAllItems()
            for item in detached {
                if row.localWorkspace {
                    item.title = String(localized: "paneCreation.localWorkspace", defaultValue: "New Local Workspace", table: "PaneCreation", bundle: .localizedModule)
                }
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Pane creation and the full command catalog share the visible + menu.
    public func makePaneCreationMenu(target: ActionTargetRef, machineID: String? = nil) -> NSMenu {
        // The person's arrangement of the New Tab Button menu (Settings > Menus), then All commands….
        let entries = contextMenuEntries(for: .newTab) + [.separator, .action("commandPalette")]
        let menu = makeContextMenu(for: .newTab, target: target, entries: entries, machineID: machineID)
        if let commands = menu.items.last, Self.menuRun(of: commands)?.id == "commandPalette",
           let symbol = descriptor(for: "commandPalette")?.symbol {
            // The catalog treats the default command symbol as no icon; this discovery row names it explicitly.
            commands.title = String(localized: "paneCreation.allCommands", defaultValue: "All commands…", table: "PaneCreation", bundle: .localizedModule)
            commands.image = .menuSymbol(symbol)
        }
        return menu
    }
}
