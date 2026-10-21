public import CoreGraphics
import MessagesLabSidebar

/// The Home list's header: search, the Unread toggle and compose on one row, in a band as tall as
/// the transcript's header (Messages' toolbar row). Only the search field's width changes with the
/// list's width. The avatar-only list (below `CmuxSidebarView.compactBelow`) shows no row, as
/// Messages: compose moves to the chat's top-left (`HomeChatColumnView`), and an open search (⌘F,
/// type-to-search) takes the band until it closes. Frames are in the header's flipped coordinates
/// (y down).
public struct HomeSidebarHeaderLayout: Equatable, Sendable {
    /// The band the row sits in; the list starts under it.
    static let band: CGFloat = 52
    /// The buttons' and the field's height (the field is a capsule of this height).
    static let side: CGFloat = 28
    static let inset: CGFloat = 10
    static let gap: CGFloat = 6
    /// The narrowest search field: its glass and "Search" still show.
    static let minimumField: CGFloat = 72

    /// The avatar-only list: no search field, Unread toggle or compose in the band.
    public private(set) var compact: Bool
    /// The search capsule; zero-sized in the avatar-only list while the search is closed.
    public private(set) var search: CGRect
    /// The Unread toggle; zero-sized in the avatar-only list.
    public private(set) var filter: CGRect
    /// The list's compose button; zero-sized in the avatar-only list.
    public private(set) var compose: CGRect
    /// An open search in the avatar-only list covers the band until it closes.
    public private(set) var buttonsCovered: Bool
    /// Where the list starts.
    public var listTop: CGFloat { Self.band }

    /// The list at `width` shows avatars only, and so no header row.
    public static func isCompact(width: CGFloat) -> Bool { width < CmuxSidebarView.compactBelow }

    init(width: CGFloat, searchOpen: Bool) {
        let width = max(0, width)
        let y = ((Self.band - Self.side) / 2).rounded()
        compact = Self.isCompact(width: width)
        if compact {
            filter = .zero
            compose = .zero
            buttonsCovered = searchOpen
            search = searchOpen ? CGRect(x: Self.inset, y: y, width: max(0, width - 2 * Self.inset), height: Self.side)
                : CGRect(x: Self.inset, y: y, width: 0, height: 0)
            return
        }
        let field = max(Self.minimumField, width - 2 * Self.inset - 2 * (Self.side + Self.gap))
        search = CGRect(x: Self.inset, y: y, width: field, height: Self.side)
        filter = CGRect(x: search.maxX + Self.gap, y: y, width: Self.side, height: Self.side)
        compose = CGRect(x: filter.maxX + Self.gap, y: y, width: Self.side, height: Self.side)
        buttonsCovered = false
    }
}
