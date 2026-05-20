import SwiftUI

struct AgentSessionPanelView: View {
    @ObservedObject var panel: AgentSessionPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        Group {
            if isVisibleInUI {
                AgentSessionWebRenderer(
                    panel: panel,
                    backgroundColor: .clear,
                    onRequestPanelFocus: onRequestPanelFocus
                )
                .id(panel.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(Double(portalPriority))
            } else {
                Color(nsColor: appearance.contentBackgroundColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }
}
