import Foundation

struct CommandPaletteRestoreFocusTarget {
    let workspaceId: UUID
    let panelId: UUID
    let intent: PanelFocusIntent
}
