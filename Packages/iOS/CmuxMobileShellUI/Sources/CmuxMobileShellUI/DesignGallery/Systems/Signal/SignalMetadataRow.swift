#if DEBUG
import SwiftUI

/// Presents one uppercase label and monospaced value in the Session spec table.
struct SignalMetadataRow: View {
    let label: String
    let value: String
    let state: GalleryAgentState?
    let theme: SignalTheme

    var body: some View {
        HStack(spacing: 12) {
            SignalSectionLabel(text: label, color: theme.secondaryText)
                .frame(width: 76, alignment: .leading)

            if let state {
                let style = SignalStatusStyle(state: state, theme: theme)
                SignalStatusSquare(color: style.color)
            }

            Text(value)
                .font(.system(.footnote, design: .monospaced, weight: .regular))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
        }
    }
}
#endif
