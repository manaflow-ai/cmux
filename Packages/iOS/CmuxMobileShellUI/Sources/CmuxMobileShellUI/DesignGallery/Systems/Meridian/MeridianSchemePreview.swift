#if DEBUG
import SwiftUI

/// Shows Meridian's accent and status tints over one forced system appearance.
struct MeridianSchemePreview: View {
    let title: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.label)

            HStack(spacing: 10) {
                statusChip(.needsYou)
                statusChip(.running)
                statusChip(.done)
                statusChip(.failed)
                statusChip(.idle)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            theme.background,
            in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .stroke(theme.separator, lineWidth: 0.5)
        }
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }

    private func statusChip(_ state: GalleryAgentState) -> some View {
        MeridianStatusSymbol(state: state, font: .headline)
            .frame(width: 26, height: 26)
    }
}
#endif
