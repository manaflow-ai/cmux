import CmuxSettings
import SwiftUI

/// Leading indicator rendered by DynamicNotchKit in the menu-bar compact state.
struct DynamicNotchNotificationCompactLeadingView: View {
    let model: DynamicNotchNotificationTrayModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let appearance = model.trayAppearance
        Group {
            if model.phase == .compact {
                Image(systemName: "bell.badge.fill")
                    .font(.system(
                        size: appearance.dimension(.compactIconSize),
                        weight: .semibold
                    ))
                    .foregroundStyle(
                        appearance.color(.compactIconColor, system: .accentColor)
                    )
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, appearance.dimension(.compactHorizontalPadding))
        .padding(.vertical, appearance.dimension(.compactVerticalPadding))
        .frame(
            width: model.phase == .compact ? compactSectionWidth : 0,
            height: appearance.dimension(.compactHeight)
        )
        .background(
            appearance.color(.compactBackgroundColor, system: .clear)
                .opacity(Double(appearance.dimension(.compactBackgroundOpacity))),
            in: RoundedRectangle(
                cornerRadius: appearance.dimension(.compactCornerRadius),
                style: .continuous
            )
        )
        .accessibilityHidden(model.phase != .compact)
        .animation(
            reduceMotion
                ? nil
                : .snappy(duration: Double(appearance.dimension(.animationDuration))),
            value: model.phase
        )
    }

    private var compactSectionWidth: CGFloat {
        max(
            1,
            (
                model.trayAppearance.dimension(.compactWidth)
                    - model.trayAppearance.dimension(.compactSpacing)
            ) / 2
        )
    }
}

/// Pending count rendered by DynamicNotchKit in the menu-bar compact state.
struct DynamicNotchNotificationCompactTrailingView: View {
    let model: DynamicNotchNotificationTrayModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let appearance = model.trayAppearance
        Group {
            if model.phase == .compact {
                Text(model.notifications.count, format: .number)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(
                        appearance.color(.compactTextColor, system: .white)
                    )
                    .contentTransition(.numericText())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, appearance.dimension(.compactHorizontalPadding))
        .padding(.vertical, appearance.dimension(.compactVerticalPadding))
        .frame(
            width: model.phase == .compact ? compactSectionWidth : 0,
            height: appearance.dimension(.compactHeight)
        )
        .background(
            appearance.color(.compactBackgroundColor, system: .clear)
                .opacity(Double(appearance.dimension(.compactBackgroundOpacity))),
            in: RoundedRectangle(
                cornerRadius: appearance.dimension(.compactCornerRadius),
                style: .continuous
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(localized: "notifications.title", defaultValue: "Notifications")
        )
        .accessibilityValue(Text(model.notifications.count, format: .number))
        .accessibilityHidden(model.phase != .compact)
        .animation(
            reduceMotion
                ? nil
                : .snappy(duration: Double(appearance.dimension(.animationDuration))),
            value: model.notifications.count
        )
        .animation(
            reduceMotion
                ? nil
                : .snappy(duration: Double(appearance.dimension(.animationDuration))),
            value: model.phase
        )
    }

    private var compactSectionWidth: CGFloat {
        max(
            1,
            (
                model.trayAppearance.dimension(.compactWidth)
                    - model.trayAppearance.dimension(.compactSpacing)
            ) / 2
        )
    }
}
