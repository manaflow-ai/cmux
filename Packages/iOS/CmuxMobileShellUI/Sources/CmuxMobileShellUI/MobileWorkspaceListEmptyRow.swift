#if os(iOS)
import CmuxMobileSupport
import SwiftUI

struct MobileWorkspaceListEmptyRow: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            VStack(spacing: 7) {
                Text(
                    L10n.string(
                        "mobile.workspaces.empty.title",
                        defaultValue: "No workspaces yet"
                    )
                )
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                Text(
                    L10n.string(
                        "mobile.workspaces.empty.message",
                        defaultValue: "Enable iOS pairing in cmux Settings > Mobile on your Mac, sign in to the same cmux account on both devices, and keep cmux running. Your Mac and its workspaces will appear here after pairing is enabled."
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 56)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileWorkspaceEmptyState")
    }
}
#endif
