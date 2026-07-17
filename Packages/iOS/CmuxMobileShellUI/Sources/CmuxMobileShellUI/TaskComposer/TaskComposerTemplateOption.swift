#if os(iOS)
import CmuxMobileShellModel
import SwiftUI

/// One agent/template choice in the horizontal launch selector.
struct TaskComposerTemplateOption: View {
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
                        .frame(width: 40, height: 40)
                    TaskTemplateIcon(value: template.icon, size: 22)
                        .frame(width: 40, height: 40)
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
            .frame(width: 86, height: 78)
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
