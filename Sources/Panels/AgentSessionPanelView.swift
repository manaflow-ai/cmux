import CmuxFoundation
import SwiftUI
import CmuxSettings

struct AgentSessionPanelView: View {
    @Environment(\.cmuxAccentColor) private var cmuxAccent
    let panel: AgentSessionPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        Group {
            if isVisibleInUI {
                if panel.rendererKind == .typescript {
                    AcpmuxChatWebRenderer(
                        panel: panel,
                        isFocused: isFocused,
                        backgroundColor: appearance.contentBackgroundColor,
                        theme: AgentSessionWebTheme.resolve(appearance: appearance),
                        onRequestPanelFocus: onRequestPanelFocus
                    )
                } else {
                    AcpmuxChatPaneRepresentable(
                        panel: panel,
                        theme: AcpmuxChatTheme.resolve(appearance: appearance, accent: cmuxAccent)
                    )
                }
                .id(panel.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(Double(portalPriority))
            } else {
                Color.clear
            }
        }
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }
}
