#if DEBUG
import CmuxMobileSupport
import SwiftUI

/// Presents Phosphor's two thumb-reachable hub commands on compatible glass.
struct PhosphorCommandBar: View {
    let showsApprove: Bool

    @Environment(\.colorScheme) private var colorScheme
    private let typography = PhosphorTypography()

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)

        HStack(spacing: 8) {
            if showsApprove {
                Button(action: {}) {
                    Label("Approve", systemImage: "checkmark")
                        .font(typography.bodySemibold)
                        .foregroundStyle(theme.statusNeedsYou)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            theme.statusNeedsYou.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.statusNeedsYou.opacity(0.55), lineWidth: 1)
                        }
                }
                .buttonStyle(PhosphorPressButtonStyle())
            }

            Button(action: {}) {
                Label("New workspace", systemImage: "plus")
                    .font(typography.bodySemibold)
                    .foregroundStyle(theme.isDark ? theme.textPrimary : theme.bg1)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PhosphorPressButtonStyle())
        }
        .padding(8)
        .mobileGlassField(cornerRadius: 12)
    }
}
#endif
