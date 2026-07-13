#if DEBUG
import CmuxMobileSupport
import SwiftUI

/// Groups Meridian's session actions in morph-ready glass circles with a material fallback.
struct MeridianActionCluster: View {
    let approvalPending: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                buttonRow
            }
        } else {
            buttonRow
        }
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }

    private var buttonRow: some View {
        HStack(spacing: 12) {
            circleButton(symbol: "keyboard", label: "Show keyboard", prominent: false)
            circleButton(
                symbol: "checkmark",
                label: DesignGalleryFixtures.approvalActions[0],
                prominent: approvalPending
            )
            circleButton(symbol: "ellipsis", label: "More actions", prominent: false)
        }
    }

    private func circleButton(
        symbol: String,
        label: String,
        prominent: Bool
    ) -> some View {
        Button {} label: {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(prominent ? theme.accentForeground : theme.label)
                .frame(width: 48, height: 48)
                .background {
                    if prominent {
                        Circle().fill(theme.accent)
                    }
                }
                .mobileGlassCircle()
                .contentShape(Circle())
        }
        .buttonStyle(MeridianPressButtonStyle())
        .accessibilityLabel(label)
    }
}
#endif
