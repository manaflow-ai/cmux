#if DEBUG
import SwiftUI

/// Supplies a custom three-way appearance selector without default picker chrome.
struct PhosphorAppearanceControl: View {
    @Binding var selection: Int

    @Environment(\.colorScheme) private var colorScheme
    private var typography = PhosphorTypography()

    private let choices = ["System", "Light", "Dark"]

    var body: some View {
        let theme = PhosphorTheme(scheme: colorScheme)

        HStack(spacing: 4) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                Button {
                    selection = index
                } label: {
                    Text(choice)
                        .font(selection == index ? typography.captionSemibold : typography.caption)
                        .foregroundStyle(selection == index ? theme.textPrimary : theme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if selection == index {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(theme.bg1)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(theme.hairline, lineWidth: 1)
                                    }
                            }
                        }
                }
                .buttonStyle(PhosphorPressButtonStyle())
            }
        }
        .padding(4)
        .background(theme.bg2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
#endif
