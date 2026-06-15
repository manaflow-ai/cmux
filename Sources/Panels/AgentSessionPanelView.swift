import SwiftUI

struct AgentSessionPanelView: View {
    let panel: AgentSessionPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        AgentSessionWebRenderer(
            panel: panel,
            isFocused: isFocused,
            backgroundColor: appearance.contentBackgroundColor,
            theme: AgentSessionWebTheme.resolve(appearance: appearance),
            onRequestPanelFocus: onRequestPanelFocus
        )
        .id(panel.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(isVisibleInUI)
        .zIndex(Double(portalPriority))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}
