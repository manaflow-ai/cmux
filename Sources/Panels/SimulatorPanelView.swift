import SwiftUI

/// Bonsplit-pane host for the iOS Simulator viewer. Reuses `SimulatorListView`.
struct SimulatorPanelView: View {
    @ObservedObject var panel: SimulatorPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: (UUID) -> Void

    var body: some View {
        SimulatorListView(initialUDID: panel.preferredUDID, isVisibleInUI: isVisibleInUI)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
                }
            }
            .onTapGesture {
                onRequestPanelFocus(panel.id)
            }
    }
}
