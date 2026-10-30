import AppKit
import CmuxNextActions

/// The palette rows of the tab actions that act on a whole selection read so ("Close Tabs", "Add
/// Tabs to New Group") while the focused strip has several tabs selected, as the tab menu does
/// (`NSMenu.namingTabSelection`).
struct TabSelectionTitles {
    let context: AppActionContext

    /// Sets each selection-aware action's palette title; call after the actions are bound.
    @MainActor func install(in registry: ActionRegistry) {
        for id: ActionID in ["closeTab", "palette.toggleTabPin", "duplicateTab", "palette.moveTabToNewWorkspace", "tab.moveToNewWindow",
                             "tabGroup.create", "tabGroup.addTab", "tabGroup.removeTab", "tab.stash"] {
            ActionTargetTitles.setPaletteTitle(id, in: registry) { [context] in
                guard let strip = context.services.windows.active?.focusedPane?.stripModel, strip.selectedTabIDs.count > 1 else { return nil }
                return NSMenu.tabSelectionTitle(id, pins: strip.pinsAll(strip.selectedTabIDs))
            }
        }
    }
}
