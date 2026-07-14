#if DEBUG
import SwiftUI

/// Displays an amber approval request with paired, clearly separated responses.
struct PhosphorApprovalCard: View {
    let question: String
    let timeText: String

    @Environment(\.colorScheme) private var colorScheme
    private let typography = PhosphorTypography()

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                PhosphorStatusDot(state: .needsYou)
                Image(systemName: theme.statusSymbol(.needsYou))
                    .font(.system(size: 11, weight: .bold))
                Text("Approval required")
                    .font(typography.captionSemibold)
                Spacer(minLength: 8)
                Text(timeText)
                    .font(typography.monoCaption)
                    .monospacedDigit()
            }
            .foregroundStyle(theme.statusNeedsYou)

            Text(question)
                .font(typography.body)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(action: {}) {
                    Text(DesignGalleryFixtures.approvalActions[1])
                        .font(typography.bodySemibold)
                        .foregroundStyle(theme.statusFailed)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(theme.bg2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(PhosphorPressButtonStyle())

                Button(action: {}) {
                    Text(DesignGalleryFixtures.approvalActions[0])
                        .font(typography.bodySemibold)
                        .foregroundStyle(theme.isDark ? theme.textPrimary : theme.bg1)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            theme.accent,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(PhosphorPressButtonStyle())
            }
        }
        .padding(12)
        .background(theme.bg1, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.statusNeedsYou, lineWidth: 1)
        }
    }
}
#endif
