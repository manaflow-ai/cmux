public import AppKit

/// The one card style every hover preview shares: the tab strip's tab and group cards, the
/// sidebar's group cards, a link chip's card and (at the sidebar's density, `SidebarHoverCardMetrics`)
/// the sidebar's workspace card. One padding, one radius, one title and secondary text style, and
/// one spacing scale, so no card reads as its own design (Leo 2026-11-06: "there's not, like, some
/// sort of unified style kind of situation going on").
///
/// A row with nothing to show hides and gives up its gap: no card keeps an empty line.
///
/// ```swift
/// let style = HoverCardStyle.shared
/// stack.spacing = style.rowGap
/// ```
@MainActor
public struct HoverCardStyle: Sendable {
    /// The style every card reads; its values follow the density and text size live.
    public static var shared: HoverCardStyle { HoverCardStyle() }

    public init() {}

    /// Around a card's content.
    public var padding: CGFloat { Metrics.space4 }
    /// From the title's last line to the first row under it.
    public var titleGap: CGFloat { Metrics.space2 }
    /// Between two rows.
    public var rowGap: CGFloat { Metrics.space2 }
    /// Before a thumbnail or another picture under the rows.
    public var mediaGap: CGFloat { Metrics.space4 }
    /// The card's corners: the floating panels' radius (`HoverCardPanel.cornerRadius`).
    public var cornerRadius: CGFloat { HoverCardPanel.cornerRadius }
    /// The card's title (a tab's, a group's, a link's name).
    public var titleFont: NSFont { Typography.bodyEmphasized }
    /// Every row under the title.
    public var secondaryFont: NSFont { Typography.body }
    /// The title's ink, in the theme scope that is active (call it inside `performWithTheme`).
    public var titleInk: HoverCardTone { .primary }
    /// The rows' ink.
    public var secondaryInk: HoverCardTone { .secondary }
}
