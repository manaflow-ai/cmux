#if DEBUG
import SwiftUI

/// Pairs a Meridian Dynamic Type role name with a live SF Pro sample.
struct MeridianTypeSample: View {
    let role: String
    let sample: String
    let font: Font

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(role)
                .font(.caption)
                .foregroundStyle(theme.secondaryLabel)
            Text(sample)
                .font(font)
                .foregroundStyle(theme.label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var theme: MeridianTheme {
        MeridianTheme(scheme: colorScheme)
    }
}
#endif
