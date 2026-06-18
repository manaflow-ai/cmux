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
/// where ``SidebarTabItemFontScale/scale(for:)`` returns `1.0`. Every metric is
/// the corresponding base value multiplied by ``fontScale``.
///
/// ```swift
/// let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: settings.sidebarFontScale)
/// Image(systemName: "chevron.down")
///     .font(.system(size: metrics.chevronFontSize, weight: .semibold))
///     .frame(width: metrics.chevronFrame, height: metrics.chevronFrame)
/// ```
struct SidebarWorkspaceGroupHeaderMetrics: Equatable {
    /// The sidebar font scale; `1.0` at the default sidebar font size and
    /// proportionally larger as the configured `sidebar-font-size` grows.
    let fontScale: CGFloat

    /// Creates header metrics for the given sidebar font scale.
    /// - Parameter fontScale: The scale from ``SidebarTabItemFontScale/scale(for:)``;
    ///   `1.0` at the default sidebar font size.
    init(fontScale: CGFloat) {
        self.fontScale = fontScale
    }

    /// Chevron glyph point size at the default sidebar font size.
    static let baseChevronFontSize: CGFloat = 9
    /// Chevron tap-target frame edge at the default sidebar font size.
    static let baseChevronFrame: CGFloat = 14
    /// Folder/group icon point size at the default sidebar font size.
    static let baseIconFontSize: CGFloat = 11
    /// Folder/group icon frame edge at the default sidebar font size.
    static let baseIconFrame: CGFloat = 14
    /// Group name point size at the default sidebar font size.
    static let baseNameFontSize: CGFloat = 11
    /// Unread badge point size at the default sidebar font size.
    static let baseUnreadFontSize: CGFloat = 10
    /// Unread badge horizontal padding at the default sidebar font size.
    static let baseUnreadHorizontalPadding: CGFloat = 5
    /// Unread badge vertical padding at the default sidebar font size.
    static let baseUnreadVerticalPadding: CGFloat = 1
    /// Plus-button glyph point size at the default sidebar font size.
    static let basePlusFontSize: CGFloat = 11
    /// Plus-button frame edge at the default sidebar font size.
    static let basePlusFrame: CGFloat = 18

    /// Scaled chevron glyph point size.
    var chevronFontSize: CGFloat { Self.baseChevronFontSize * fontScale }
    /// Scaled chevron tap-target frame edge.
    var chevronFrame: CGFloat { Self.baseChevronFrame * fontScale }
    /// Scaled folder/group icon point size.
    var iconFontSize: CGFloat { Self.baseIconFontSize * fontScale }
    /// Scaled folder/group icon frame edge.
    var iconFrame: CGFloat { Self.baseIconFrame * fontScale }
    /// Scaled group name point size.
    var nameFontSize: CGFloat { Self.baseNameFontSize * fontScale }
    /// Scaled unread badge point size.
    var unreadFontSize: CGFloat { Self.baseUnreadFontSize * fontScale }
    /// Scaled unread badge horizontal padding.
    var unreadHorizontalPadding: CGFloat { Self.baseUnreadHorizontalPadding * fontScale }
    /// Scaled unread badge vertical padding.
    var unreadVerticalPadding: CGFloat { Self.baseUnreadVerticalPadding * fontScale }
    /// Scaled plus-button glyph point size.
    var plusFontSize: CGFloat { Self.basePlusFontSize * fontScale }
    /// Scaled plus-button frame edge.
    var plusFrame: CGFloat { Self.basePlusFrame * fontScale }
}
