import SwiftUI
import CmuxAppKitSupportUI

/// A Bonsplit terminal tab whose panel registry entry is stale must remain
/// explainable instead of falling through to an empty view.
struct TerminalPanelUnavailableView: View {
    let appearance: PanelAppearance

    var body: some View {
        VStack(spacing: 10) {
            CmuxSystemSymbolImage(
                magnified: "exclamationmark.triangle",
                pointSize: 28,
                tint: Color(nsColor: .secondaryLabelColor)
            )
            Text(String(localized: "cloud.overlay.manual.unavailable.title", defaultValue: "Cloud terminal unavailable"))
                .cmuxFont(size: 14, weight: .semibold)
                .foregroundStyle(.primary)
            Text(String(localized: "cloud.overlay.manual.reopen.detail", defaultValue: "Close this tab and reopen the terminal from the Cloud sidebar."))
                .cmuxFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: appearance.contentBackgroundColor))
    }
}
