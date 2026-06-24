import AppKit
import CmuxAppKitSupportUI
import Foundation
import SwiftUI

/// Resolves the terminal background color used to tint browser, sidebar, and
/// canvas chrome so they match the live Ghostty terminal backdrop.
///
/// The pure clamp + composite math lives in
/// `CmuxAppKitSupportUI.WindowAppearanceSnapshot`; this resolver routes through
/// it and adds the app-only default-background lookup behind an injected
/// provider closure (`defaults`). Tests construct an instance with a fixed
/// provider; the running app uses `appDefault`, whose provider reads
/// `GhosttyApp.shared.engineRuntime`.
struct GhosttyBackgroundTheme {
    /// The current default terminal background color and opacity.
    struct Defaults {
        /// Current default background color.
        let color: NSColor

        /// Current default background opacity.
        let opacity: Double

        /// Creates a default-background pair.
        init(color: NSColor, opacity: Double) {
            self.color = color
            self.opacity = opacity
        }
    }

    /// Supplies the current default background color and opacity.
    private let defaults: () -> Defaults

    /// Creates a resolver backed by the given default-background provider.
    init(defaults: @escaping () -> Defaults) {
        self.defaults = defaults
    }

    /// App-wired resolver reading the live Ghostty engine-runtime defaults.
    ///
    /// The engine-runtime default-background reads are non-isolated (a plain
    /// `GhosttyEngineRuntime` class), so the resolver and its provider stay
    /// non-isolated to match the call sites that resolve chrome color off the
    /// main actor (e.g. the canvas `themeProvider`).
    static var appDefault: GhosttyBackgroundTheme {
        GhosttyBackgroundTheme {
            let runtime = GhosttyApp.shared.engineRuntime
            return Defaults(
                color: runtime.defaultBackgroundColor,
                opacity: runtime.defaultBackgroundOpacity
            )
        }
    }

    /// Clamps opacity into the visible `0...1` range.
    static func clampedOpacity(_ opacity: Double) -> CGFloat {
        WindowAppearanceSnapshot.clampedOpacity(opacity)
    }

    /// Returns `backgroundColor` composited over the window background at `opacity`.
    static func color(backgroundColor: NSColor, opacity: Double) -> NSColor {
        WindowAppearanceSnapshot.compositedTerminalColor(
            backgroundColor: backgroundColor,
            opacity: opacity
        )
    }

    /// Resolves the background color from a Ghostty default-change notification,
    /// using explicit fallbacks when the payload is missing keys.
    static func color(
        from notification: Notification?,
        fallbackColor: NSColor,
        fallbackOpacity: Double
    ) -> NSColor {
        let userInfo = notification?.userInfo
        let backgroundColor =
            (userInfo?[GhosttyNotificationKey.backgroundColor] as? NSColor)
            ?? fallbackColor

        let opacity: Double
        if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? Double {
            opacity = value
        } else if let value = userInfo?[GhosttyNotificationKey.backgroundOpacity] as? NSNumber {
            opacity = value.doubleValue
        } else {
            opacity = fallbackOpacity
        }

        return color(backgroundColor: backgroundColor, opacity: opacity)
    }

    /// Resolves the background color from a notification, falling back to the
    /// injected current defaults when the payload is missing keys.
    func color(from notification: Notification?) -> NSColor {
        let current = defaults()
        return Self.color(
            from: notification,
            fallbackColor: current.color,
            fallbackOpacity: current.opacity
        )
    }

    /// The current default terminal background composited at its default opacity.
    func currentColor() -> NSColor {
        let current = defaults()
        return Self.color(
            backgroundColor: current.color,
            opacity: current.opacity
        )
    }
}

enum HeaderChromeIconStyle {
    static let opacity = 0.86
    static let hoveredOpacity = 0.96
    static let pressedOpacity = 1.0
    static let disabledOpacity = 0.34
    static let weight: Font.Weight = .regular
    static let foregroundColor = Color(nsColor: .secondaryLabelColor)
    static let sidebarGlyphStrokeWidth: CGFloat = 1

    static func iconFrameSize(forIconSize iconSize: CGFloat) -> CGFloat {
        HeaderChromeControlMetrics.iconFrameSize(forIconSize: iconSize)
    }

    static func symbol(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .cmuxSymbolRasterSize(RightSidebarChromeMetrics.headerIconSize, weight: weight)
    }

    static func foregroundOpacity(isHovering: Bool, isPressed: Bool, isEnabled: Bool = true) -> Double {
        guard isEnabled else { return disabledOpacity }
        if isPressed {
            return pressedOpacity
        }
        if isHovering {
            return hoveredOpacity
        }
        return opacity
    }

    static func backgroundOpacity(
        hoverBackground: Bool,
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return 0 }
        if isPressed {
            return 0.14
        }
        if isHovering {
            return hoverBackground ? 0.09 : 0.07
        }
        return 0
    }

    static func borderOpacity(
        buttonBackground: Bool,
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return buttonBackground ? 0.04 : 0 }
        if isPressed {
            return 0.11
        }
        if isHovering {
            return 0.07
        }
        return buttonBackground ? 0.05 : 0
    }
}

enum RightSidebarChromeControlStyle {
    static let modeIconSize: CGFloat = 11
    static let secondaryIconSize: CGFloat = 10
    static let labelSize: CGFloat = 11
    static let iconWeight = HeaderChromeIconStyle.weight
    static let labelWeight = HeaderChromeIconStyle.weight
    static let foregroundColor = HeaderChromeIconStyle.foregroundColor

    static func foregroundOpacity(isSelected: Bool, isHovered: Bool, isEnabled: Bool = true) -> Double {
        guard isEnabled else { return HeaderChromeIconStyle.disabledOpacity }
        if isSelected {
            return HeaderChromeIconStyle.pressedOpacity
        }
        return HeaderChromeIconStyle.foregroundOpacity(
            isHovering: isHovered,
            isPressed: false,
            isEnabled: isEnabled
        )
    }
}

struct RightSidebarChromeBarModifier: ViewModifier {
    var leadingPadding: CGFloat
    var trailingPadding: CGFloat
    var height: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.leading, leadingPadding)
            .padding(.trailing, trailingPadding)
            .padding(.vertical, RightSidebarChromeMetrics.barVerticalPadding)
            .frame(height: height)
    }
}

struct RightSidebarChromePillModifier: ViewModifier {
    var isSelected: Bool
    var isHovered: Bool
    var horizontalPadding: CGFloat = RightSidebarChromeMetrics.controlHorizontalPadding
    var geometryKeyPrefix: String?

    func body(content: Content) -> some View {
        content
            .foregroundStyle(
                RightSidebarChromeControlStyle.foregroundColor.opacity(foregroundOpacity)
            )
            .padding(.horizontal, horizontalPadding)
            .frame(height: RightSidebarChromeMetrics.controlHeight)
            .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
                keyPrefix: geometryKeyPrefix,
                isVisible: true
            )
            .background(
                RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.controlCornerRadius, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.controlCornerRadius, style: .continuous)
            )
    }

    private var foregroundOpacity: Double {
        RightSidebarChromeControlStyle.foregroundOpacity(
            isSelected: isSelected,
            isHovered: isHovered
        )
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.primary.opacity(0.10)
        }
        if isHovered {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }
}

struct RightSidebarChromeBottomBorderModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            WindowChromeBorder(
                orientation: .horizontal,
                ignoresSafeArea: false,
                refreshNotificationName: .ghosttyDefaultBackgroundDidChange,
                backgroundColorProvider: { GhosttyBackgroundTheme.appDefault.currentColor() }
            )
        }
    }
}

struct RightSidebarHeaderIconButtonStyle: ButtonStyle {
    var iconGeometryKeyPrefix: String? = nil

    func makeBody(configuration: Configuration) -> some View {
        RightSidebarHeaderIconButtonStyleBody(
            configuration: configuration,
            iconGeometryKeyPrefix: iconGeometryKeyPrefix
        )
    }
}

private struct RightSidebarHeaderIconButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let iconGeometryKeyPrefix: String?
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .symbolRenderingMode(.monochrome)
            .frame(
                width: RightSidebarChromeMetrics.headerIconFrameSize,
                height: RightSidebarChromeMetrics.headerIconFrameSize
            )
            .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
                keyPrefix: iconGeometryKeyPrefix,
                isVisible: true
            )
            .frame(
                width: RightSidebarChromeMetrics.headerControlSize,
                height: RightSidebarChromeMetrics.headerControlSize
            )
            .foregroundStyle(HeaderChromeIconStyle.foregroundColor.opacity(foregroundOpacity))
            .background {
                if backgroundOpacity > 0 {
                    RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.headerControlCornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(backgroundOpacity))
                }
            }
            .contentShape(
                RoundedRectangle(cornerRadius: RightSidebarChromeMetrics.headerControlCornerRadius, style: .continuous)
            )
            .onHover { isHovering = $0 }
    }

    private var foregroundOpacity: Double {
        HeaderChromeIconStyle.foregroundOpacity(
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
    }

    private var backgroundOpacity: Double {
        HeaderChromeIconStyle.backgroundOpacity(
            hoverBackground: false,
            isHovering: isHovering,
            isPressed: configuration.isPressed,
            isEnabled: isEnabled
        )
    }
}

extension View {
    func rightSidebarChromeBar(
        leadingPadding: CGFloat = RightSidebarChromeMetrics.barHorizontalPadding,
        trailingPadding: CGFloat = RightSidebarChromeMetrics.barHorizontalPadding,
        height: CGFloat = RightSidebarChromeMetrics.secondaryBarHeight
    ) -> some View {
        modifier(
            RightSidebarChromeBarModifier(
                leadingPadding: leadingPadding,
                trailingPadding: trailingPadding,
                height: height
            )
        )
    }

    func rightSidebarChromePill(
        isSelected: Bool,
        isHovered: Bool,
        horizontalPadding: CGFloat = RightSidebarChromeMetrics.controlHorizontalPadding,
        geometryKeyPrefix: String? = nil
    ) -> some View {
        modifier(
            RightSidebarChromePillModifier(
                isSelected: isSelected,
                isHovered: isHovered,
                horizontalPadding: horizontalPadding,
                geometryKeyPrefix: geometryKeyPrefix
            )
        )
    }

    func rightSidebarChromeBottomBorder() -> some View {
        modifier(RightSidebarChromeBottomBorderModifier())
    }

    func rightSidebarHeaderControlAlignment() -> some View {
        alignmentGuide(VerticalAlignment.center) { dimensions in
            dimensions[VerticalAlignment.center] + RightSidebarChromeMetrics.headerControlCenterAlignmentAdjustment
        }
    }
}
