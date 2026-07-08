public import CoreGraphics
public import CmuxSettings
public import SwiftUI

/// The top header row of a workspace sidebar item.
///
/// Lays out, left to right: an optional unread-count badge, an optional
/// high-memory warning glyph, an optional pinned glyph, the workspace title, and
/// a trailing close button that always reserves its width (so the title wraps or
/// truncates before the hover-revealed close corner instead of flowing under
/// it). All colors, sizes, tooltips, and the close action are resolved by the
/// caller and passed in as values/closures, so this package view holds no
/// app-target dependency and stays compatible with the snapshot-boundary rule
/// for rows under a `LazyVStack`. The title slot can be replaced with a
/// host-supplied inline editor without moving rename policy into this package.
public struct SidebarWorkspaceHeaderRow<EditingTitleContent: View>: View {
    let unreadCount: Int
    let unreadBadgeFillColor: Color
    let unreadBadgeTextColor: Color
    let unreadBadgeDiameter: CGFloat
    let unreadBadgePosition: SidebarIndicatorPosition
    let showsLoadingSpinner: Bool
    let loadingSpinnerPosition: SidebarIndicatorPosition
    let loadingSpinnerColor: Color
    let loadingSpinnerTooltip: String
    let hasMemoryWarning: Bool
    let memoryWarningTooltip: String
    let memoryWarningAccessibilityLabel: String
    let isPinned: Bool
    let pinnedTooltip: String
    let title: String
    let titleColor: Color
    let titleFontWeight: Font.Weight
    let titleLineLimit: Int
    let isTitleEditing: Bool
    let editingTitleContent: EditingTitleContent
    let pinIconColor: Color
    let closeButtonColor: Color
    let fontScale: CGFloat
    let showsCloseButton: Bool
    let closeButtonVisible: Bool
    let closeButtonWidth: CGFloat
    let closeButtonHitSize: CGFloat
    let closeButtonTooltip: String
    let onClose: () -> Void

    /// Creates the workspace header row.
    /// - Parameters:
    ///   - unreadCount: Unread count; the badge is hidden when `0`.
    ///   - unreadBadgeFillColor: Fill color for the unread badge circle.
    ///   - unreadBadgeTextColor: Foreground color for the unread count.
    ///   - unreadBadgeDiameter: Diameter of the unread badge, in points.
    ///   - hasMemoryWarning: Whether to show the high-memory warning glyph.
    ///   - memoryWarningTooltip: Tooltip for the memory warning glyph.
    ///   - memoryWarningAccessibilityLabel: Accessibility label for the glyph.
    ///   - isPinned: Whether to show the pinned glyph.
    ///   - pinnedTooltip: Tooltip for the pinned glyph.
    ///   - title: The displayed workspace title (already bounded by the caller).
    ///   - titleColor: Foreground color for the title.
    ///   - titleFontWeight: Font weight for the title.
    ///   - titleLineLimit: Maximum number of title lines.
    ///   - isTitleEditing: Whether to render `editingTitleContent` in place of
    ///     the normal title text.
    ///   - editingTitleContent: Inline title editor supplied by the app target.
    ///   - pinIconColor: Foreground color for the pinned glyph.
    ///   - closeButtonColor: Foreground color for the close button glyph.
    ///   - fontScale: Multiplier applied to base font sizes.
    ///   - showsCloseButton: Whether the close button is laid out at all (the
    ///     workspace is closable).
    ///   - closeButtonVisible: Whether the close button is currently shown
    ///     (hover/shortcut-hint state); toggled via opacity so hover never
    ///     re-lays-out the row.
    ///   - closeButtonWidth: Reserved width for the close button.
    ///   - closeButtonHitSize: Hit-test height for the close button.
    ///   - closeButtonTooltip: Tooltip for the close button.
    ///   - onClose: Invoked when the close button is pressed.
    public init(
        unreadCount: Int,
        unreadBadgeFillColor: Color,
        unreadBadgeTextColor: Color,
        unreadBadgeDiameter: CGFloat,
        unreadBadgePosition: SidebarIndicatorPosition,
        showsLoadingSpinner: Bool,
        loadingSpinnerPosition: SidebarIndicatorPosition,
        loadingSpinnerColor: Color,
        loadingSpinnerTooltip: String,
        hasMemoryWarning: Bool,
        memoryWarningTooltip: String,
        memoryWarningAccessibilityLabel: String,
        isPinned: Bool,
        pinnedTooltip: String,
        title: String,
        titleColor: Color,
        titleFontWeight: Font.Weight,
        titleLineLimit: Int,
        isTitleEditing: Bool,
        pinIconColor: Color,
        closeButtonColor: Color,
        fontScale: CGFloat,
        showsCloseButton: Bool,
        closeButtonVisible: Bool,
        closeButtonWidth: CGFloat,
        closeButtonHitSize: CGFloat,
        closeButtonTooltip: String,
        onClose: @escaping () -> Void,
        @ViewBuilder editingTitleContent: () -> EditingTitleContent
    ) {
        self.unreadCount = unreadCount
        self.unreadBadgeFillColor = unreadBadgeFillColor
        self.unreadBadgeTextColor = unreadBadgeTextColor
        self.unreadBadgeDiameter = unreadBadgeDiameter
        self.unreadBadgePosition = unreadBadgePosition
        self.showsLoadingSpinner = showsLoadingSpinner
        self.loadingSpinnerPosition = loadingSpinnerPosition
        self.loadingSpinnerColor = loadingSpinnerColor
        self.loadingSpinnerTooltip = loadingSpinnerTooltip
        self.hasMemoryWarning = hasMemoryWarning
        self.memoryWarningTooltip = memoryWarningTooltip
        self.memoryWarningAccessibilityLabel = memoryWarningAccessibilityLabel
        self.isPinned = isPinned
        self.pinnedTooltip = pinnedTooltip
        self.title = title
        self.titleColor = titleColor
        self.titleFontWeight = titleFontWeight
        self.titleLineLimit = titleLineLimit
        self.isTitleEditing = isTitleEditing
        self.editingTitleContent = editingTitleContent()
        self.pinIconColor = pinIconColor
        self.closeButtonColor = closeButtonColor
        self.fontScale = fontScale
        self.showsCloseButton = showsCloseButton
        self.closeButtonVisible = closeButtonVisible
        self.closeButtonWidth = closeButtonWidth
        self.closeButtonHitSize = closeButtonHitSize
        self.closeButtonTooltip = closeButtonTooltip
        self.onClose = onClose
    }

    private func scaledFontSize(_ baseSize: CGFloat) -> CGFloat {
        baseSize * fontScale
    }

    public var body: some View {
        let badgeOnLeading = unreadCount > 0 && unreadBadgePosition == .leading
        let badgeOnTrailing = unreadCount > 0 && unreadBadgePosition == .trailing
        let spinnerOnLeading = showsLoadingSpinner && loadingSpinnerPosition == .leading
        let spinnerOnTrailing = showsLoadingSpinner && loadingSpinnerPosition == .trailing
        let leadingStatusActive = badgeOnLeading || spinnerOnLeading
        let trailingStatusActive = badgeOnTrailing || spinnerOnTrailing
        let trailingAccessoryActive = showsCloseButton || trailingStatusActive

        HStack(alignment: .top, spacing: 8) {
            if leadingStatusActive {
                SidebarWorkspaceStatusSlot(
                    showsBadge: badgeOnLeading,
                    showsSpinner: spinnerOnLeading,
                    unreadCount: unreadCount,
                    badgeFillColor: unreadBadgeFillColor,
                    badgeTextColor: unreadBadgeTextColor,
                    diameter: unreadBadgeDiameter,
                    fontScale: fontScale,
                    spinnerColor: loadingSpinnerColor,
                    spinnerTooltip: loadingSpinnerTooltip
                )
            }

            if hasMemoryWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: scaledFontSize(11), weight: .semibold))
                    .foregroundColor(.orange)
                    .safeHelp(memoryWarningTooltip)
                    .accessibilityLabel(memoryWarningAccessibilityLabel)
            }

            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: scaledFontSize(9), weight: .semibold))
                    .foregroundColor(pinIconColor)
                    .safeHelp(pinnedTooltip)
            }

            if isTitleEditing {
                editingTitleContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            } else {
                Text(title)
                    .font(.system(size: scaledFontSize(12.5), weight: titleFontWeight))
                    .foregroundColor(titleColor)
                    .lineLimit(titleLineLimit)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }

            // The close button is a sibling that always reserves its width
            // when the workspace is closable, so the title wraps/truncates
            // before this corner instead of flowing under the hover x. Its
            // visibility toggles via opacity so hover never re-lays-out the
            // row. (Matches the group-header plus-button pattern.)
            if trailingAccessoryActive {
                ZStack(alignment: .trailing) {
                    if trailingStatusActive {
                        SidebarWorkspaceStatusSlot(
                            showsBadge: badgeOnTrailing,
                            showsSpinner: spinnerOnTrailing,
                            unreadCount: unreadCount,
                            badgeFillColor: unreadBadgeFillColor,
                            badgeTextColor: unreadBadgeTextColor,
                            diameter: unreadBadgeDiameter,
                            fontScale: fontScale,
                            spinnerColor: loadingSpinnerColor,
                            spinnerTooltip: loadingSpinnerTooltip
                        )
                        .opacity(showsCloseButton && closeButtonVisible ? 0 : 1)
                    }
                    if showsCloseButton {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .cmuxSymbolRasterSize(scaledFontSize(9), weight: .medium)
                                .foregroundColor(closeButtonColor)
                                .frame(width: closeButtonWidth, height: closeButtonHitSize, alignment: .center)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .safeHelp(closeButtonTooltip)
                        .opacity(closeButtonVisible ? 1 : 0)
                        .allowsHitTesting(closeButtonVisible)
                        .accessibilityHidden(!closeButtonVisible)
                    }
                }
                .frame(width: closeButtonWidth, height: closeButtonHitSize, alignment: .trailing)
            }
        }
    }
}

private struct SidebarWorkspaceStatusSlot: View {
    let showsBadge: Bool
    let showsSpinner: Bool
    let unreadCount: Int
    let badgeFillColor: Color
    let badgeTextColor: Color
    let diameter: CGFloat
    let fontScale: CGFloat
    let spinnerColor: Color
    let spinnerTooltip: String

    var body: some View {
        ZStack {
            if showsBadge {
                SidebarWorkspaceUnreadBadge(
                    count: unreadCount,
                    fillColor: badgeFillColor,
                    textColor: badgeTextColor,
                    diameter: diameter,
                    fontScale: fontScale
                )
                .opacity(showsSpinner ? 0 : 1)
            }
            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .tint(spinnerColor)
                    .frame(width: diameter, height: diameter)
                    .safeHelp(spinnerTooltip)
                    .accessibilityLabel(spinnerTooltip)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipped()
    }
}
