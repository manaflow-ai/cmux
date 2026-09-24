#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// A real Mac Settings capture cropped to the Mobile pane. The asset catalog
/// selects the light or dark source to match the app appearance.
struct OnboardingPairingSettingsScreenshot: View {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .aspectRatio(1030.0 / 285.0, contentMode: .fit)
            .overlay(alignment: .top) {
                Image("OnboardingPairingSettings", bundle: .module)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .keyframeAnimator(
                        initialValue: CGFloat(1),
                        repeating: isActive && scenePhase == .active && !reduceMotion
                    ) { image, zoom in
                        image.scaleEffect(zoom, anchor: .topTrailing)
                    } keyframes: { _ in
                        LinearKeyframe(1, duration: 2)
                        CubicKeyframe(1.3, duration: 1.2)
                        LinearKeyframe(1.3, duration: 3)
                        CubicKeyframe(1, duration: 1.2)
                    }
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
