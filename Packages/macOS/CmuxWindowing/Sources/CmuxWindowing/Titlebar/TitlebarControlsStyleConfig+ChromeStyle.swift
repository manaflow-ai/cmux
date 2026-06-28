public import CoreGraphics

/// Derived chrome-style geometry and interaction opacities for one titlebar
/// controls style.
///
/// These members compute purely from the config's own stored constants and the
/// shared ``HeaderChromeIconStyle`` opacity table, with no app-only coupling, so
/// they live in the package alongside ``TitlebarControlsStyleConfig`` itself.
/// The remaining geometry that reaches into app-only chrome metrics, debug
/// settings, and shortcut formatting stays app-side in a sibling extension.
extension TitlebarControlsStyleConfig {
    /// Vertical gap between the control row and the shortcut-hint pills.
    public static let shortcutHintVerticalGap: CGFloat = -3

    /// Point size for the notification badge label, derived from the badge diameter.
    public var notificationBadgeFontSize: CGFloat {
        max(7, badgeSize - 6)
    }

    /// Height reserved for a shortcut-hint pill, large enough for the control glyph.
    public var shortcutHintHeight: CGFloat {
        max(14, iconSize + 1)
    }

    /// Vertical offset placing the shortcut hints just beneath the control row.
    public var shortcutHintVerticalOffset: CGFloat {
        buttonSize + Self.shortcutHintVerticalGap
    }

    /// Whether the controls react to pointer hover for this style.
    public var shouldTrackButtonHover: Bool {
        true
    }

    /// Scale applied to a control while it is pressed (no visual press scaling).
    public static func controlPressedScale(isPressed _: Bool) -> CGFloat {
        1
    }

    /// Foreground opacity for a control glyph in the given interaction state.
    public static func controlForegroundOpacity(
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        HeaderChromeIconStyle.foregroundOpacity(isHovering: isHovering, isPressed: isPressed, isEnabled: isEnabled)
    }

    /// Background fill opacity for a control in the given interaction state.
    public func controlBackgroundOpacity(
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        HeaderChromeIconStyle.backgroundOpacity(
            hoverBackground: hoverBackground,
            isHovering: isHovering,
            isPressed: isPressed,
            isEnabled: isEnabled
        )
    }

    /// Border stroke opacity for a control in the given interaction state.
    public func controlBorderOpacity(
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        HeaderChromeIconStyle.borderOpacity(
            buttonBackground: buttonBackground,
            isHovering: isHovering,
            isPressed: isPressed,
            isEnabled: isEnabled
        )
    }
}
