import SwiftUI

/// Hosts ``AccountSignInView`` inside a workspace pane.
struct AccountSignInPanelView: View {
    let panel: AccountSignInPanel
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ScrollView {
            AccountSignInView(model: panel.model, automaticallyStartsSignIn: true)
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
        .environment(\.colorScheme, appearance.backgroundColor.isLightColor ? .light : .dark)
        .contentShape(Rectangle())
        .onTapGesture { onRequestPanelFocus() }
        .accessibilityIdentifier("AccountSignInPanel")
    }
}
