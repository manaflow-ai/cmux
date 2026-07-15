import SwiftUI

struct UsageTipCard: View {
    let presentation: UsageTipPresentation
    let onAcknowledge: () -> Void

    private var closeLabel: String {
        String(localized: "usageTips.close", defaultValue: "Close tip")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb")
                .cmuxFont(size: 10, weight: .medium)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text(presentation.tip.title)
                .cmuxFont(size: 11, weight: .medium)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 2)

            if let shortcutLabel = presentation.shortcutLabel {
                Text(shortcutLabel)
                    .cmuxFont(size: 9, weight: .semibold, design: .rounded)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
            }

            Button(action: onAcknowledge) {
                Image(systemName: "xmark")
                    .cmuxFont(size: 8, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .accessibilityLabel(closeLabel)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minWidth: 200, idealWidth: 260, maxWidth: 280, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.14), radius: 7, x: 0, y: 2)
        .accessibilityElement(children: .contain)
    }
}
