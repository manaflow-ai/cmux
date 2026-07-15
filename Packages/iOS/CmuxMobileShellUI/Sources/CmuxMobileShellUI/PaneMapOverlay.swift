import CmuxMobileSupport
import SwiftUI

/// Slice 3's pane-map shell; Slice 4 supplies the proportional pane canvas.
struct PaneMapOverlay: View {
    let workspaceName: String
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(workspaceName)
                    .font(.headline)
                    .foregroundStyle(TerminalPalette.foreground)
                    .lineLimit(1)

                Spacer(minLength: 12)

                Button(action: dismiss) {
                    Text(L10n.string("mobile.paneMap.done", defaultValue: "Done"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TerminalPalette.foreground)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .mobileGlassPill()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("MobilePaneMapDone")
            }
            .padding(16)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalPalette.background.ignoresSafeArea())
        .accessibilityIdentifier("MobilePaneMapOverlay")
    }
}
