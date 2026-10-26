public import CoreGraphics
import MessagesLabSidebar

/// The Home list's header: search and the Unread toggle on one row, in a band as tall as the
/// transcript's header (Messages' toolbar row). Only the search field's width changes with the
/// list's width. Compose is never in the list: as in Messages it sits at the chat's top-left
/// (`HomeChatColumnView`) at every width (the user, 2026-10-21). The avatar-only list (below
/// `CmuxSidebarView.compactBelow`) shows no row, and an open search (⌘F, type-to-search) takes the
/// band until it closes. Frames are in the header's flipped coordinates (y down).
/// With the window's traffic lights over the row (the docked Home pane has no tab bar, so with the
/// sidebar hidden the list is at the window's top-left), the row starts after them (`leading`).
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
    /// The list's compose button: always zero-sized (compose is the chat's, `HomeChatColumnView`).
    public private(set) var compose: CGRect = .zero
    /// An open search in the avatar-only list covers the band until it closes.
    public private(set) var buttonsCovered: Bool
    /// Where the row starts: the inset, or past the window's traffic lights over it.
    public private(set) var leading: CGFloat
    /// Where the list starts.
    public var listTop: CGFloat { Self.band }
    /// The row's frame at `width`: what the traffic lights must not cover.
    static func row(width: CGFloat) -> CGRect { CGRect(x: 0, y: ((band - side) / 2).rounded(), width: max(0, width), height: side) }

    /// The list at `width` shows avatars only, and so no header row.
    public static func isCompact(width: CGFloat) -> Bool { width < CmuxSidebarView.compactBelow }

    /// - Parameter windowControls: Points from the row's leading edge the window's traffic lights
    ///   take (`WindowTitlebar.windowControlsClearance`); 0 when none lie over it.
    init(width: CGFloat, searchOpen: Bool, windowControls: CGFloat = 0) {
        let width = max(0, width)
        let y = Self.row(width: width).minY
        compact = Self.isCompact(width: width)
        // Past the lights the field narrows (down to a capsule as wide as it is tall); a list too
        // narrow for even that keeps the inset, so the field never opens zero-wide.
        let buttons = compact ? 0 : Self.side + Self.gap
        let cleared = max(Self.inset, windowControls)
        let x = width - cleared - Self.inset - buttons >= Self.side ? cleared : Self.inset
        leading = x
        if compact {
            filter = .zero
            buttonsCovered = searchOpen
            search = searchOpen ? CGRect(x: x, y: y, width: max(0, width - x - Self.inset), height: Self.side)
                : CGRect(x: x, y: y, width: 0, height: 0)
            return
        }
        let room = width - x - Self.inset - buttons
        // Past the lights `room` is at least `side` (above); at the inset the old floor holds.
        let field = x == Self.inset ? max(Self.minimumField, room) : room
        search = CGRect(x: x, y: y, width: field, height: Self.side)
        filter = CGRect(x: search.maxX + Self.gap, y: y, width: Self.side, height: Self.side)
        buttonsCovered = false
    }
}
