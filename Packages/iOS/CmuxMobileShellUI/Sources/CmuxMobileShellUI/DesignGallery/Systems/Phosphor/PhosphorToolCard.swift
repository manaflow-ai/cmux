#if DEBUG
import SwiftUI

/// Renders a bordered tool invocation with command and three-line output preview.
struct PhosphorToolCard: View {
    let title: String
    let command: String
    let output: String
    let timeText: String

    @Environment(\.colorScheme) private var colorScheme
    private var typography = PhosphorTypography()

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(typography.bodySemibold)
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 8)
                Text(timeText)
                    .font(typography.monoCaption)
                    .monospacedDigit()
                    .foregroundStyle(theme.textTertiary)
            }

            Text(command)
                .font(typography.data)
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(theme.bg2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(output)
                .font(typography.monoCaption)
                .foregroundStyle(theme.textTertiary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(theme.bg1, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.hairline, lineWidth: 1)
        }
    }
}
#endif
