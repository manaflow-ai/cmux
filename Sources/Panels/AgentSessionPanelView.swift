import CmuxFoundation
import SwiftUI
import CmuxSettings

struct AgentSessionPanelView: View {
    @Environment(\.cmuxAccentColor) private var cmuxAccent
    @AppStorage(SessionContentWidthSettings.maxWidthKey)
    private var storedSessionContentMaximumWidth = SessionContentWidthSettings.noMaximumWidth
    @AppStorage(SessionContentWidthSettings.alignmentKey)
    private var storedSessionContentAlignment = SessionContentAlignment.center.rawValue
    let panel: AgentSessionPanel
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
                    isFocused: isFocused,
                    backgroundColor: appearance.contentBackgroundColor,
                    theme: AgentSessionWebTheme.resolve(appearance: appearance, accent: cmuxAccent),
                    sessionContentWidthPresentation: sessionContentWidthPresentation,
                    onRequestPanelFocus: onRequestPanelFocus
                )
                .id(panel.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(Double(portalPriority))
            } else {
                Color.clear
            }
        }
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }

    private var sessionContentWidthPresentation: SessionContentWidthPresentation {
        SessionContentWidthPresentation(
            storedMaximumWidth: storedSessionContentMaximumWidth,
            storedAlignment: storedSessionContentAlignment
        )
    }
}
