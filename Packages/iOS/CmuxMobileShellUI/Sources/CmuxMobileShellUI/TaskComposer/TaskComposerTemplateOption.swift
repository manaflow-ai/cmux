#if os(iOS)
import CmuxMobileShellModel
import SwiftUI

/// One agent/template choice in the horizontal launch selector.
struct TaskComposerTemplateOption: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(MobileDisplaySettings.self) private var displaySettings
    @ScaledMetric(relativeTo: .caption) private var cardWidth: CGFloat = 91
    @ScaledMetric(relativeTo: .caption) private var cardHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .caption) private var iconDiameter: CGFloat = 29
    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 17

    let template: MobileTaskTemplate
    let isSelected: Bool
    let isDisabled: Bool
    var shellIconVariant: TaskComposerShellIconVariant?
    let action: () -> Void

    init(
        template: MobileTaskTemplate,
        isSelected: Bool,
        isDisabled: Bool,
        shellIconVariant: TaskComposerShellIconVariant? = nil,
        action: @escaping () -> Void
    ) {
        self.template = template
        self.isSelected = isSelected
        self.isDisabled = isDisabled
        self.shellIconVariant = shellIconVariant
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(
                            isSelected
                                ? Color.accentColor.opacity(0.16 * resolvedShellIconVariant.circleOpacityScale)
                                : Color.primary.opacity(0.055 * resolvedShellIconVariant.circleOpacityScale)
                        )
                        .frame(
                            width: resolvedIconDiameter * resolvedShellIconVariant.circleScale,
                            height: resolvedIconDiameter * resolvedShellIconVariant.circleScale
                        )
                    TaskTemplateIcon(
                        value: template.icon,
                        size: resolvedIconSize,
                        shellVariant: resolvedShellIconVariant
                    )
                        .frame(width: resolvedIconDiameter, height: resolvedIconDiameter)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .offset(x: 3, y: -2)
                            .accessibilityHidden(true)
                    }
                }

                Text(template.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .frame(width: resolvedCardWidth, height: resolvedCardHeight)
            .background(
                isSelected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.038),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.62) : Color.primary.opacity(0.065),
                        lineWidth: isSelected ? 1.25 : 1
                    )
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityHint(TaskComposerSheet.templateAccessibilityHint)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.snappy(duration: 0.2), value: isSelected)
    }

    private var resolvedCardWidth: CGFloat {
        min(cardWidth, dynamicTypeSize.isAccessibilitySize ? 122 : 98)
    }

    private var resolvedCardHeight: CGFloat {
        min(cardHeight, dynamicTypeSize.isAccessibilitySize ? 60 : 52)
    }

    private var resolvedIconDiameter: CGFloat {
        min(iconDiameter, dynamicTypeSize.isAccessibilitySize ? 34 : 31)
    }

    private var resolvedIconSize: CGFloat {
        min(iconSize, dynamicTypeSize.isAccessibilitySize ? 20 : 18)
    }

    private var resolvedShellIconVariant: TaskComposerShellIconVariant {
        guard template.icon == "terminal" else { return .current }
        #if DEBUG
        return shellIconVariant ?? displaySettings.taskComposerShellIconVariant
        #else
        return .current
        #endif
    }
}
#endif
