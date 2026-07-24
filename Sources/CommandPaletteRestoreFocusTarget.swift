import AppKit
import Foundation

struct CommandPaletteRestoreFocusTarget {
    let workspaceId: UUID
    let panelId: UUID
    let intent: PanelFocusIntent
    let dockStore: DockSplitStore?
    let sourceWindow: NSWindow?

    init(
        workspaceId: UUID,
        panelId: UUID,
        intent: PanelFocusIntent,
        dockStore: DockSplitStore? = nil,
        sourceWindow: NSWindow? = nil
    ) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.intent = intent
        self.dockStore = dockStore
        self.sourceWindow = sourceWindow
    }
}
