import SwiftUI

/// Opens the Mobile Connect pairing window from the trailing title-bar cluster.
struct MobileConnectTitlebarButton: View {
    @State private var isHovered = false

    private var helpTitle: String {
        String(localized: "command.mobileConnect.title", defaultValue: "Connect iPhone/iPad")
    }

    var body: some View {
        if CmuxFeatureFlags.shared.isMobileConnectButtonEnabled {
            Button {
                MobilePairingWindowController.shared.show()
            } label: {
                Image(systemName: "iphone")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .frame(width: 24, height: 22, alignment: .center)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isHovered ? Color(nsColor: .quaternaryLabelColor) : .clear)
                    )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .safeHelp(helpTitle)
            .accessibilityLabel(helpTitle)
            .accessibilityIdentifier("TitlebarMobileConnectButton")
        }
    }
}
