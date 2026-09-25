#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A real Mac Settings capture cropped to the Mobile pane. The asset catalog
/// selects the light or dark source to match the app appearance. Keeping the
/// capture still makes the Mobile pairing setting easy to read.
struct OnboardingPairingSettingsScreenshot: View {
    var body: some View {
        Color.clear
            .aspectRatio(1030.0 / 285.0, contentMode: .fit)
            .overlay(alignment: .top) {
                Image("OnboardingPairingSettings", bundle: .module)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel(L10n.string(
                "mobile.whatsNew.pairing.screenshotLabel",
                defaultValue: "cmux Mac Settings, Mobile section, showing Enable iOS pairing."
            ))
            .accessibilityIdentifier("MobileOnboardingPairingSettingsScreenshot")
    }
}
#endif
