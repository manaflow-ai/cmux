import SwiftUI

struct UsageTipCard: View {
    let presentation: UsageTipPresentation
    let onAcknowledge: () -> Void
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    private var closeLabel: String {
        String(localized: "usageTips.close", defaultValue: "Close tip")
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            cardContent
            ScrollView(.vertical) {
                cardContent
            }
        }
        .frame(minWidth: 220, idealWidth: 344, maxWidth: 344, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.13), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.24), radius: 16, x: 0, y: 7)
        .accessibilityElement(children: .contain)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 8) {
                Text(String(localized: "usageTips.badge", defaultValue: "TIP"))
                    .cmuxFont(size: 9, weight: .bold, design: .rounded)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor))

                Spacer(minLength: 8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .cmuxFont(size: 10, weight: .semibold)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel(closeLabel)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    headline
                    shortcutPill
                }
                VStack(alignment: .leading, spacing: 7) {
                    headline
                    shortcutPill
                }
            }

            Text(presentation.tip.body)
                .cmuxFont(size: 12)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(action: onOpenSettings) {
                    Text(String(localized: "usageTips.settingsLink", defaultValue: "Usage tip settings…"))
                        .cmuxFont(size: 11, weight: .medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .focusable(false)

                Spacer()

                Button(String(localized: "usageTips.gotIt", defaultValue: "Got it"), action: onAcknowledge)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .focusable(false)
            }
        }
        .padding(14)
    }

    private var headline: some View {
        Text(presentation.tip.title)
            .cmuxFont(size: 14, weight: .bold)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var shortcutPill: some View {
        if let shortcutLabel = presentation.shortcutLabel {
            ShortcutHintPill(text: shortcutLabel, fontSize: 10, emphasis: 0.9)
        }
    }
}
