import CmuxNextIcons
import SwiftUI

/// Tier label next to the app name.
struct TierBadge: View {
    var tier: AppTier
    @Environment(\.permissionColors) private var colors

    var body: some View {
        HStack(spacing: 3) {
            Icon(tier == .unverified ? .securityInsecure : .trustVerified, size: 12)
            Text(AppPermissionsStrings.tier(tier)).font(colors.caption)
        }
        .foregroundStyle(colors.tier(tier))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(colors.field))
    }
}
