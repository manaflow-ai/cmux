import CmuxFoundation
import CoreGraphics

/// Font sizes, icon/control frames, and badge padding for
/// ``SidebarWorkspaceGroupHeaderView``, derived from the sidebar font scale.
///
/// The collapsible workspace group/folder header must grow proportionally with
/// the configurable sidebar font size, just like the workspace rows below it.
/// `TabItemView` already scales its subviews by `settings.sidebarFontScale`
/// (see ``SidebarTabItemFontScale``); this type is the single place that
/// applies the same scale to the group header so the two grow at the same rate
/// from one scaling path.
///
/// The `base*` constants are the design sizes at the default sidebar font size,
/// where ``SidebarTabItemFontScale/scale(for:)`` returns `1.0`. Most metrics are
/// the corresponding base value multiplied by ``fontScale``. Control frames keep
/// a minimum hit size so they stay aligned with normal workspace row controls.
///
/// ```swift
/// let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: settings.sidebarFontScale)
/// Image(systemName: "chevron.down")
///     .cmuxFont(size: metrics.chevronFontSize, weight: .semibold)
///     .frame(width: metrics.chevronFrame, height: metrics.chevronFrame)
/// ```
struct SidebarWorkspaceGroupHeaderMetrics: Equatable {
    /// The sidebar font scale; `1.0` at the default sidebar font size and
    /// proportionally larger as the configured `sidebar-font-size` grows.
    let fontScale: CGFloat

    /// Whether the group-divider treatment is on. Off keeps today's flat look:
    /// the 11 pt header name and no top gap above the header (see ``nameFontSize``
    /// and ``topGap(isFirstRenderedRow:)``).
    let showsGroupDividers: Bool

    /// Creates header metrics for the given sidebar font scale.
    /// - Parameters:
    ///   - fontScale: The scale from ``SidebarTabItemFontScale/scale(for:)``;
    ///     `1.0` at the default sidebar font size.
    ///   - showsGroupDividers: Whether the group-divider treatment is on. The
    ///     default `false` preserves today's flat-list sizing for callers that
    ///     do not opt in.
    init(fontScale: CGFloat, showsGroupDividers: Bool = false) {
        self.fontScale = fontScale
        self.showsGroupDividers = showsGroupDividers
    }

    /// Chevron glyph point size at the default sidebar font size.
    static let baseChevronFontSize: CGFloat = 9
    /// Chevron tap-target frame edge at the default sidebar font size.
    static let baseChevronFrame: CGFloat = 14
    /// Folder/group icon point size at the default sidebar font size.
    static let baseIconFontSize: CGFloat = 11
    /// Folder/group icon frame edge at the default sidebar font size.
    static let baseIconFrame: CGFloat = 14
    /// Pinned group glyph point size at the default sidebar font size.
    static let basePinnedIconFontSize: CGFloat = 9
    /// Group name point size at the default sidebar font size when group
    /// dividers are off; the flat-list baseline.
    static let baseNameFontSize: CGFloat = 11
    /// Group name point size at the default sidebar font size when group
    /// dividers are on, matching the workspace title size so a header reads as
    /// the start of its group rather than a smaller caption.
    static let baseNameFontSizeWithDividers: CGFloat = 12.5
    /// Top gap above the header band at the default sidebar font size, giving
    /// each group air above it. Suppressed for the first rendered row and when
    /// group dividers are off (see ``topGap(isFirstRenderedRow:)``).
    static let baseTopGap: CGFloat = 10
    /// Unread badge point size at the default sidebar font size.
    static let baseUnreadFontSize: CGFloat = 10
    /// Unread badge horizontal padding at the default sidebar font size.
    static let baseUnreadHorizontalPadding: CGFloat = 5
    /// Unread badge vertical padding at the default sidebar font size.
    static let baseUnreadVerticalPadding: CGFloat = 1
    /// Plus-button glyph point size at the default sidebar font size.
    static let basePlusFontSize: CGFloat = 11
    /// Plus-button frame edge at the default sidebar font size. This matches the
    /// normal workspace close-button frame so their centers share the same x-position.
    static let basePlusFrame: CGFloat = 16
    /// Leading inset for a header-bottom drop indicator whose resolved scope is
    /// the group's member list rather than the root hierarchy.
    static let memberScopedDropIndicatorLeadingInset: CGFloat = SidebarWorkspaceGroupingMetrics.memberIndent

    /// Scaled chevron glyph point size.
    var chevronFontSize: CGFloat { Self.baseChevronFontSize * fontScale }
    /// Scaled chevron tap-target frame edge.
    var chevronFrame: CGFloat { Self.baseChevronFrame * fontScale }
    /// Scaled folder/group icon point size.
    var iconFontSize: CGFloat { Self.baseIconFontSize * fontScale }
    /// Scaled folder/group icon frame edge.
    var iconFrame: CGFloat { Self.baseIconFrame * fontScale }
    /// Scaled pinned group glyph point size.
    var pinnedIconFontSize: CGFloat { Self.basePinnedIconFontSize * fontScale }
    /// Scaled group name point size: the larger divider size when group
    /// dividers are on, otherwise the flat-list baseline.
    var nameFontSize: CGFloat {
        (showsGroupDividers ? Self.baseNameFontSizeWithDividers : Self.baseNameFontSize) * fontScale
    }
    /// Scaled top gap above the header band, before the first-row and
    /// setting-off exemptions applied by ``topGap(isFirstRenderedRow:)``.
    var topGap: CGFloat { Self.baseTopGap * fontScale }
    /// Scaled unread badge point size.
    var unreadFontSize: CGFloat { Self.baseUnreadFontSize * fontScale }
    /// Scaled unread badge horizontal padding.
    var unreadHorizontalPadding: CGFloat { Self.baseUnreadHorizontalPadding * fontScale }
    /// Scaled unread badge vertical padding.
    var unreadVerticalPadding: CGFloat { Self.baseUnreadVerticalPadding * fontScale }
    /// Scaled plus-button glyph point size.
    var plusFontSize: CGFloat { Self.basePlusFontSize * fontScale }
    /// Scaled plus-button frame edge.
    var plusFrame: CGFloat { max(Self.basePlusFrame, Self.basePlusFrame * fontScale) }
    /// Leading inset for a group-scoped append indicator rendered by the header.
    var groupScopedBottomDropIndicatorLeadingInset: CGFloat { Self.memberScopedDropIndicatorLeadingInset }
    /// Stable drop-hit height for the group header, without reading SwiftUI layout.
    var dropTargetHeight: CGFloat {
        let contentHeight = max(chevronFrame, iconFrame, plusFrame, nameFontSize + 4)
        return max(24 * fontScale, contentHeight + 10)
    }

    /// The effective top gap for this header: the scaled ``topGap`` when group
    /// dividers are on, and `0` for the first rendered row (so the pinned Home
    /// group stays flush under the title bar) or when dividers are off
    /// (restoring today's flush layout).
    /// - Parameter isFirstRenderedRow: Whether this header is the first row the
    ///   list actually renders, a stable list-position fact — not the drag-only
    ///   `isFirstRow` the drop indicators use.
    func topGap(isFirstRenderedRow: Bool) -> CGFloat {
        guard showsGroupDividers, !isFirstRenderedRow else { return 0 }
        return topGap
    }
}
