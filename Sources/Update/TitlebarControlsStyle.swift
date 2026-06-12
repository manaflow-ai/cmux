import AppKit
import Bonsplit
import Combine
import SwiftUI


// MARK: - Titlebar controls style & layout metrics
enum TitlebarControlsStyle: Int, CaseIterable, Identifiable {
    case classic
    case compact
    case roomy
    case pillGroup
    case softButtons

    var id: Int { rawValue }

    var menuTitle: String {
        switch self {
        case .classic:
            return "Classic"
        case .compact:
            return "Compact"
        case .roomy:
            return "Roomy"
        case .pillGroup:
            return "Pill Group"
        case .softButtons:
            return "Soft Buttons"
        }
    }

    var config: TitlebarControlsStyleConfig {
        switch self {
        case .classic:
            return TitlebarControlsStyleConfig(
                spacing: 6,
                iconSize: HeaderChromeControlMetrics.iconSize,
                buttonSize: HeaderChromeControlMetrics.buttonSize,
                badgeSize: 12,
                badgeOffset: CGSize(width: 3, height: -3),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: HeaderChromeControlMetrics.cornerRadius,
                hoverBackground: false
            )
        case .compact:
            return TitlebarControlsStyleConfig(
                spacing: 5,
                iconSize: 11,
                buttonSize: 18,
                badgeSize: 11,
                badgeOffset: CGSize(width: 3, height: -3),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: 5,
                hoverBackground: false
            )
        case .roomy:
            return TitlebarControlsStyleConfig(
                spacing: 7,
                iconSize: 13,
                buttonSize: 22,
                badgeSize: 13,
                badgeOffset: CGSize(width: 3, height: -3),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: false,
                buttonCornerRadius: 7,
                hoverBackground: false
            )
        case .pillGroup:
            return TitlebarControlsStyleConfig(
                spacing: 5,
                iconSize: 12,
                buttonSize: 20,
                badgeSize: 12,
                badgeOffset: CGSize(width: 3, height: -3),
                groupBackground: false,
                groupPadding: EdgeInsets(top: 1, leading: 3, bottom: 1, trailing: 3),
                buttonBackground: false,
                buttonCornerRadius: 6,
                hoverBackground: true
            )
        case .softButtons:
            return TitlebarControlsStyleConfig(
                spacing: 6,
                iconSize: 12,
                buttonSize: 21,
                badgeSize: 12,
                badgeOffset: CGSize(width: 3, height: -3),
                groupBackground: false,
                groupPadding: EdgeInsets(),
                buttonBackground: true,
                buttonCornerRadius: 6,
                hoverBackground: false
            )
        }
    }
}

struct TitlebarControlsStyleConfig {
    let spacing: CGFloat
    let iconSize: CGFloat
    let buttonSize: CGFloat
    let badgeSize: CGFloat
    let badgeOffset: CGSize
    let groupBackground: Bool
    let groupPadding: EdgeInsets
    let buttonBackground: Bool
    let buttonCornerRadius: CGFloat
    let hoverBackground: Bool
}

enum TitlebarControlsVisualMetrics {
    static let verticalLift: CGFloat = 0

    static func liftedYOffset(_ yOffset: CGFloat) -> CGFloat {
        yOffset + verticalLift
    }
}

func titlebarNotificationBadgeFontSize(for config: TitlebarControlsStyleConfig) -> CGFloat {
    max(7, config.badgeSize - 6)
}

func titlebarControlPressedScale(isPressed _: Bool) -> CGFloat {
    1
}

enum TitlebarControlsLayoutMetrics {
    static let outerLeadingPadding: CGFloat = TitlebarControlsHitRegions.outerLeadingPadding
    private static let hintTrailingBaseInset: CGFloat = 8
    /// Leading inset the controls content sits at inside the accessory; must match the
    /// `.padding(.leading, …)` applied to `controlsGroup` in the view body.
    static let hintLeadingPadding: CGFloat = HeaderChromeControlMetrics.titlebarControlsLeadingPadding
    /// Extra trailing room past the rightmost pill for its capsule stroke and shadow.
    private static let hintShadowMargin: CGFloat = 4

    static func hintTrailingInset(titlebarShortcutHintXOffset: Double = ShortcutHintDebugSettings.defaultTitlebarHintX) -> CGFloat {
        max(0, ShortcutHintDebugSettings.clamped(titlebarShortcutHintXOffset))
            + hintTrailingBaseInset
    }

    private static func buttonRowWidth(config: TitlebarControlsStyleConfig) -> CGFloat {
        let buttonCount = CGFloat(TitlebarShortcutHintActionSlot.allCases.count)
        let gapCount = max(0, buttonCount - 1)
        return (buttonCount * config.buttonSize) + (gapCount * config.spacing)
    }

    private static func buttonCenterX(
        for slot: TitlebarShortcutHintActionSlot,
        config: TitlebarControlsStyleConfig
    ) -> CGFloat {
        let index = CGFloat(slot.rawValue)
        return config.groupPadding.leading
            + (index * (config.buttonSize + config.spacing))
            + (config.buttonSize / 2.0)
    }

    static func hintInterval(
        for slot: TitlebarShortcutHintActionSlot,
        width: CGFloat,
        config: TitlebarControlsStyleConfig,
        xOffset: CGFloat
    ) -> ClosedRange<CGFloat> {
        let centerX = buttonCenterX(for: slot, config: config) + xOffset
        return (centerX - (width / 2.0))...(centerX + (width / 2.0))
    }

    static func contentSize(
        config: TitlebarControlsStyleConfig,
        titlebarShortcutHintXOffset: Double = ShortcutHintDebugSettings.defaultTitlebarHintX
    ) -> NSSize {
        // Two width requirements; reserve the larger so neither the buttons nor the
        // shortcut hints are clipped by the accessory's allocated frame.
        let buttonReservation = outerLeadingPadding
            + config.groupPadding.leading
            + buttonRowWidth(config: config)
            + config.groupPadding.trailing
            + hintTrailingInset(titlebarShortcutHintXOffset: titlebarShortcutHintXOffset)
        // Drive the reservation from the planner's actual rightmost hint edge so the
        // overlap-shift the planner applies (which the fixed inset above ignores) is
        // always covered. This is what prevents the rightmost pill from clipping.
        let hintReservation = hintLeadingPadding
            + titlebarHintLayoutRightmostExtent(
                config: config,
                titlebarShortcutHintXOffset: titlebarShortcutHintXOffset
            )
            + hintShadowMargin
        return NSSize(
            width: max(buttonReservation, hintReservation),
            height: max(
                WindowChromeMetrics.appTitlebarHeight,
                config.groupPadding.top + config.buttonSize + config.groupPadding.bottom
            )
        )
    }

    static func containerHeight(contentHeight: CGFloat, titlebarHeight: CGFloat) -> CGFloat {
        max(contentHeight, titlebarHeight)
    }

    static func leadingOffset(
        trafficLightFrame _: NSRect?,
        debugSnapshot: MinimalModeTitlebarDebugSnapshot
    ) -> CGFloat {
        MinimalModeTitlebarDebugSettings.leftControlsXOffset(
            leadingInset: debugSnapshot.leftControlsLeadingInset
        )
    }

    static func yOffset(
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        trafficLightFrame: NSRect?,
        debugSnapshot: MinimalModeTitlebarDebugSnapshot
    ) -> CGFloat {
        let baseYOffset: CGFloat
        if let trafficLightFrame, !trafficLightFrame.isEmpty {
            baseYOffset = max(0, trafficLightFrame.midY - (contentHeight / 2.0))
        } else {
            baseYOffset = max(0, (containerHeight - contentHeight) / 2.0)
        }
        let debugYOffset = CGFloat(
            MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset
                - debugSnapshot.leftControlsTopInset
        )
        return TitlebarControlsVisualMetrics.liftedYOffset(baseYOffset + debugYOffset)
    }
}

func titlebarControlForegroundOpacity(isHovering: Bool, isPressed: Bool) -> Double {
    titlebarControlForegroundOpacity(isHovering: isHovering, isPressed: isPressed, isEnabled: true)
}

func titlebarControlForegroundOpacity(isHovering: Bool, isPressed: Bool, isEnabled: Bool) -> Double {
    HeaderChromeIconStyle.foregroundOpacity(isHovering: isHovering, isPressed: isPressed, isEnabled: isEnabled)
}

func titlebarControlBackgroundOpacity(
    config: TitlebarControlsStyleConfig,
    isHovering: Bool,
    isPressed: Bool
) -> Double {
    titlebarControlBackgroundOpacity(config: config, isHovering: isHovering, isPressed: isPressed, isEnabled: true)
}

func titlebarControlBackgroundOpacity(
    config: TitlebarControlsStyleConfig,
    isHovering: Bool,
    isPressed: Bool,
    isEnabled: Bool
) -> Double {
    HeaderChromeIconStyle.backgroundOpacity(
        hoverBackground: config.hoverBackground,
        isHovering: isHovering,
        isPressed: isPressed,
        isEnabled: isEnabled
    )
}

func titlebarControlBorderOpacity(
    config: TitlebarControlsStyleConfig,
    isHovering: Bool,
    isPressed: Bool
) -> Double {
    titlebarControlBorderOpacity(config: config, isHovering: isHovering, isPressed: isPressed, isEnabled: true)
}

func titlebarControlBorderOpacity(
    config: TitlebarControlsStyleConfig,
    isHovering: Bool,
    isPressed: Bool,
    isEnabled: Bool
) -> Double {
    HeaderChromeIconStyle.borderOpacity(
        buttonBackground: config.buttonBackground,
        isHovering: isHovering,
        isPressed: isPressed,
        isEnabled: isEnabled
    )
}

