import SwiftUI

/// The risk tone mark: a dot (neutral read scopes are hollow).
struct ToneDot: View {
    var tone: AppRiskTone
    @Environment(\.permissionColors) private var colors

    var body: some View {
        Circle()
            .strokeBorder(colors.tone(tone), lineWidth: tone == .neutral ? 1 : 0)
            .background(Circle().fill(tone == .neutral ? .clear : colors.tone(tone)))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// Tier label next to the app name.
struct TierBadge: View {
    var tier: AppTier
    @Environment(\.permissionColors) private var colors

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: tier == .unverified ? "exclamationmark.triangle" : "checkmark.seal")
                .font(.system(size: 9, weight: .semibold))
            Text(AppPermissionsStrings.tier(tier)).font(colors.caption)
        }
        .foregroundStyle(colors.tier(tier))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(colors.field))
    }
}

/// App icon: the manifest symbol in a gray rounded square.
struct AppGlyph: View {
    var symbol: String
    var size: CGFloat = 32
    @Environment(\.permissionColors) private var colors

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(colors.text)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(colors.field))
            .accessibilityHidden(true)
    }
}
