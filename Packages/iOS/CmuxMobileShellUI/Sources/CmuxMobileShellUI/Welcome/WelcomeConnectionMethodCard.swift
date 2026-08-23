#if os(iOS)
import SwiftUI

/// One selectable connection-method explanation card on the connect stage.
///
/// Renders as a radio-style card: leading symbol, title with optional badge,
/// explanatory subtitle, and a trailing selection mark. Selection state is
/// owned by the caller.
struct WelcomeConnectionMethodCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    /// A short trailing chip next to the title, e.g. “Recommended”.
    let badge: String?
    let isSelected: Bool
    let accessibilityID: String
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(
                        isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary)
                    )
            }
            .padding(14)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.55) : .clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
#endif
