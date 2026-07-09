public import AppKit
public import SwiftUI
public import CmuxSidebar
import CmuxFoundation
import Foundation

/// The resolved active/selection styling palette for one workspace sidebar row
/// (`TabItemView`).
///
/// A pure value snapshot computed from the row's `SidebarTabItemSettingsSnapshot`
/// plus the per-row `isActive`/`colorScheme`/explicit-rail inputs. It owns the
/// active-foreground inversion, selected-workspace background/foreground colors,
/// unread-badge and progress colors, border styling, font weight/scale, and the
/// shortcut-hint emphasis. Lifted byte-identically from `TabItemView`'s private
/// computed-var band so the pure styling math lives with the sidebar UI package;
/// `TabItemView` keeps holding `Tab`/`TabManager` and builds this palette from
/// its snapshot props. Pure compute over the snapshot, `Bool`, `ColorScheme`, and
/// optional hex strings, using only `SidebarSelectionColors`/`SidebarContrastMath`
/// and `NSColor(hex:)`; no `Tab`/`TabManager`/`Workspace` reach.
public struct SidebarTabItemColorPalette {
    /// The resolved sidebar tab-item settings driving every styling decision.
    public let settings: SidebarTabItemSettingsSnapshot
    /// Whether this row is the active workspace.
    public let isActive: Bool
    /// The effective color scheme of the surrounding view.
    public let colorScheme: ColorScheme
    /// The custom color hex when this row shows a leading rail, otherwise `nil`.
    /// Only its `nil`-ness is consulted (`showsLeadingRail`); the app resolves
    /// the rail color itself.
    public let explicitRailColorHex: String?

    /// Creates a palette from one render pass's value inputs.
    public init(
        settings: SidebarTabItemSettingsSnapshot,
        isActive: Bool,
        colorScheme: ColorScheme,
        explicitRailColorHex: String?
    ) {
        self.settings = settings
        self.isActive = isActive
        self.colorScheme = colorScheme
        self.explicitRailColorHex = explicitRailColorHex
    }

    /// The user's custom selection color hex, if any.
    public var sidebarSelectionColorHex: String? {
        settings.selectionColorHex
    }

    /// The user's custom notification-badge color hex, if any.
    public var sidebarNotificationBadgeColorHex: String? {
        settings.notificationBadgeColorHex
    }

    /// The selected-workspace background color for this row's color scheme and
    /// custom selection hex.
    public var selectedWorkspaceBackgroundNSColor: NSColor {
        SidebarSelectionColors.sidebarSelectedWorkspaceBackgroundNSColor(
            for: colorScheme,
            sidebarSelectionColorHex: sidebarSelectionColorHex
        )
    }

    /// The readable foreground color over the selected-workspace background at
    /// the given `opacity`.
    public func selectedWorkspaceForegroundNSColor(opacity: CGFloat) -> NSColor {
        SidebarSelectionColors.sidebarSelectedWorkspaceForegroundNSColor(
            on: selectedWorkspaceBackgroundNSColor,
            opacity: opacity
        )
    }

    /// The workspace title font weight.
    public var titleFontWeight: Font.Weight {
        .semibold
    }

    /// The sidebar font scale derived from the Ghostty sidebar font size.
    public var fontScale: CGFloat {
        settings.sidebarFontScale
    }

    /// Scales `baseSize` by `fontScale`.
    public func scaledFontSize(_ baseSize: CGFloat) -> CGFloat {
        baseSize * fontScale
    }

    /// Whether this row renders a colored leading rail.
    public var showsLeadingRail: Bool {
        explicitRailColorHex != nil
    }

    /// The active-row border line width for the current indicator style.
    public var activeBorderLineWidth: CGFloat {
        switch settings.activeTabIndicatorStyle {
        case .leftRail:
            return 0
        case .solidFill:
            return isActive ? 1.5 : 0
        }
    }

    /// The active-row border color for the current indicator style.
    public var activeBorderColor: Color {
        guard isActive else { return .clear }
        switch settings.activeTabIndicatorStyle {
        case .leftRail:
            return .clear
        case .solidFill:
            return Color.primary.opacity(0.5)
        }
    }

    /// Whether the active row inverts its foreground onto the selected
    /// background.
    public var usesInvertedActiveForeground: Bool {
        isActive
    }

    /// The primary text color, inverted onto the selected background when active.
    public var activePrimaryTextColor: Color {
        usesInvertedActiveForeground
            ? Color(nsColor: selectedWorkspaceForegroundNSColor(opacity: 1.0))
            : .primary
    }

    /// The secondary text color at `opacity`, inverted onto the selected
    /// background when active.
    public func activeSecondaryColor(_ opacity: Double = 0.75) -> Color {
        usesInvertedActiveForeground
            ? Color(nsColor: selectedWorkspaceForegroundNSColor(opacity: CGFloat(opacity)))
            : .secondary
    }

    /// The unread-badge fill color (custom badge hex, inverted primary, or
    /// accent).
    public var activeUnreadBadgeFillColor: Color {
        if let hex = sidebarNotificationBadgeColorHex, let nsColor = NSColor(hex: hex) {
            return Color(nsColor: nsColor)
        }
        return usesInvertedActiveForeground ? activePrimaryTextColor.opacity(0.25) : SidebarSelectionColors.accentColor()
    }

    /// The unread-badge text color.
    public var activeUnreadBadgeTextColor: Color {
        usesInvertedActiveForeground ? activePrimaryTextColor : .white
    }

    /// The progress-bar track color.
    public var activeProgressTrackColor: Color {
        usesInvertedActiveForeground ? activeSecondaryColor(0.15) : Color.secondary.opacity(0.2)
    }

    /// The progress-bar fill color.
    public var activeProgressFillColor: Color {
        usesInvertedActiveForeground ? activeSecondaryColor(0.8) : SidebarSelectionColors.accentColor()
    }

    /// The shortcut-hint emphasis (opacity) for active vs inactive rows.
    public var shortcutHintEmphasis: Double {
        usesInvertedActiveForeground ? 1.0 : 0.9
    }
}
