import AppKit
import Bonsplit
import CmuxHomeCore

/// Chief-specific creation and focus behavior for a right Dock.
extension DockSplitStore {
    /// Shows a Chief conversation in the Dock, reusing an existing matching tab.
    ///
    /// The Home conversation remains mounted separately. A Dock tab is a normal
    /// Bonsplit panel, so it can be moved, split, closed, and restored like any
    /// terminal or browser tab.
    @discardableResult
    func openOrFocusChiefSurface(
        conversationID: ConversationID?,
        focus: Bool = true,
        preferredPane: PaneID? = nil
    ) -> UUID? {
        ensureLoaded()
        if let existing = panels.values.compactMap({ $0 as? ChiefPanel }).first(where: {
            $0.conversationID == conversationID
        }) {
            if focus {
                focusPanelFromDockInteraction(existing.id, window: NSApp.keyWindow ?? NSApp.mainWindow)
            }
            return existing.id
        }
        guard let pane = preferredPane ?? bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first else {
            return nil
        }
        guard let panelID = newSurface(
            kind: .chief,
            inPane: pane,
            focus: false,
            conversationID: conversationID
        ) else {
            return nil
        }
        if focus {
            focusPanelFromDockInteraction(panelID, window: NSApp.keyWindow ?? NSApp.mainWindow)
        }
        return panelID
    }
}
