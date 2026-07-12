import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import SwiftUI

struct MobileMacUpdateHintBanner: View {
    let hint: MobileMacUpdateHint
    let macDisplayName: String?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.teal)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("mobile.macUpdateHint.title", defaultValue: "Mac update adds features"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(Self.bodyText(hint: hint, macName: macDisplayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L10n.string(
                "mobile.macUpdateHint.dismiss",
                defaultValue: "Don't show again for this version"
            ))
            .accessibilityIdentifier("MobileMacUpdateHintDismissButton")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileMacUpdateHintBanner")
    }

    static func bodyText(hint: MobileMacUpdateHint, macName: String?) -> String {
        let displayName = macName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if let displayName, !displayName.isEmpty {
            resolvedName = displayName
        } else {
            resolvedName = L10n.string("mobile.macUpdateHint.genericMacName", defaultValue: "Your Mac")
        }
        let featureList = ListFormatter.localizedString(
            byJoining: hint.features.map(MobileMacUpdateFeatureDisplay.name(for:))
        )
        let format = L10n.string(
            "mobile.macUpdateHint.bodyFormat",
            defaultValue: "%1$@ is on cmux %2$@. Updating to %3$@ or later adds: %4$@."
        )
        return String(
            format: format,
            resolvedName,
            hint.macAppVersion.description,
            hint.minimumMacVersion.description,
            featureList
        )
    }
}
