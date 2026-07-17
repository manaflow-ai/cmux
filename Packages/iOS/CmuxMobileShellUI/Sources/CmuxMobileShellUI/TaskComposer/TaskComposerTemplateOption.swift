#if os(iOS)
import CmuxMobileShellModel
import SwiftUI

/// One agent/template choice in the horizontal launch selector.
struct TaskComposerTemplateOption: View {
    @ScaledMetric(relativeTo: .caption) private var cardWidth: CGFloat = 86
    @ScaledMetric(relativeTo: .caption) private var cardHeight: CGFloat = 78
    @ScaledMetric(relativeTo: .caption) private var iconDiameter: CGFloat = 40
    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 22

    let template: MobileTaskTemplate
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055))
                        .frame(width: iconDiameter, height: iconDiameter)
                    TaskTemplateIcon(value: template.icon, size: iconSize)
                        .frame(width: iconDiameter, height: iconDiameter)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .offset(x: 4, y: -3)
                            .accessibilityHidden(true)
                    }
                }

                Text(template.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(width: cardWidth, height: cardHeight)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.075),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityHint(TaskComposerSheet.templateAccessibilityHint)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.snappy(duration: 0.2), value: isSelected)
    }
}
#endif
