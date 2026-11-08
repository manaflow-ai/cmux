import Foundation

struct CommandPaletteRestoreFocusTarget {
    let host: PanelHost
    let panelId: UUID
    let intent: PanelFocusIntent

    init(
        host: PanelHost,
        panelId: UUID,
        intent: PanelFocusIntent
    ) {
        self.host = host
        self.panelId = panelId
        self.intent = intent
    }

    init(
        workspaceId: UUID,
        panelId: UUID,
        intent: PanelFocusIntent
    ) {
        self.init(
            host: .workspace(workspaceId),
            panelId: panelId,
            intent: intent
        )
    }
}
