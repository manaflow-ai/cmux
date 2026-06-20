import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TerminalTabOverviewCard: View {
    private static let previewLineLimit = 12

    let item: TerminalTabOverviewItem
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                terminalPreview
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture(perform: onSelect)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        onSelect()
                    }

                if canClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white.opacity(0.92), .black.opacity(0.38))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("mobile.terminal.overview.close", defaultValue: "Close Terminal"))
                    .accessibilityIdentifier("MobileTerminalOverviewClose-\(item.id.rawValue)")
                }
            }

            HStack(spacing: 6) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if item.isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel(L10n.string("mobile.terminal.overview.selected", defaultValue: "Selected"))
                }
            }
            .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("MobileTerminalOverviewCard-\(item.id.rawValue)")
    }

    private var terminalPreview: some View {
        VStack(alignment: .leading, spacing: 2) {
            if item.previewLines.isEmpty {
                Spacer(minLength: 0)
                Text(L10n.string("mobile.terminal.overview.noPreview", defaultValue: "No preview yet"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                ForEach(Array(item.previewLines.prefix(Self.previewLineLimit).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 220, alignment: .topLeading)
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.08, green: 0.085, blue: 0.09))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(item.isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: item.isSelected ? 3 : 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 7)
    }
}
