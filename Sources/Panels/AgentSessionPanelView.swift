import SwiftUI

struct AgentSessionPanelView: View {
    @ObservedObject var panel: AgentSessionPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        if isVisibleInUI {
            AgentSessionWebRenderer(
                panel: panel,
                backgroundColor: appearance.backgroundColor,
                onRequestPanelFocus: onRequestPanelFocus
            )
            .id(panel.id)
            .zIndex(Double(portalPriority))
        } else {
            Color(nsColor: appearance.backgroundColor)
        }
    }
}
