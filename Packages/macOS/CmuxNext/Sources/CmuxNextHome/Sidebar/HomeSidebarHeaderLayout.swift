public import CoreGraphics
import MessagesLabSidebar

/// The Home list's header: search and the Unread toggle on one row, in a band as tall as the
/// transcript's header (Messages' toolbar row). Only the search field's width changes with the
/// list's width. Compose is never in the list: as in Messages it sits at the chat's top-left
/// (`HomeChatColumnView`) at every width (the user, 2026-10-21). The avatar-only list (below
/// `CmuxSidebarView.compactBelow`) shows no row, and an open search (⌘F, type-to-search) takes the
/// band until it closes. Frames are in the header's flipped coordinates (y down).
///
/// Under the window's traffic lights (the window's sidebar closed, the list at the window's left
/// edge) the header is Messages' (the user, 2026-10-28, "we should just match"): the lights have
/// the top row to themselves with the Unread toggle at its right end on their line, and the
/// search field spans the list on the row under them. The avatar-only list keeps its band; an open
/// search there sits under the lights too.
public struct HomeSidebarHeaderLayout: Equatable, Sendable {
    /// The band the row sits in; the list starts under it.
    static let band: CGFloat = 52
    /// The filter circle's diameter and the search capsule's height, as in Messages (its glass
    /// filter and search field are one height).
    static let side: CGFloat = 30
    /// The filter circle's least room above it under the traffic lights: cmux's lights sit higher
    /// than Messages', so on their line the circle shrinks rather than run off the window's top.
    static let topMargin: CGFloat = 1
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
    /// Where the list starts: under the band, or under the search row when the traffic lights
    /// take the top row.
    public private(set) var listTop: CGFloat = Self.band
    /// The search row's distance under the traffic lights (and the filter circle on their line)
    /// and the list's under the search field.
    static let rowGap: CGFloat = 10

    /// The list at `width` shows avatars only, and so no header row.
    public static func isCompact(width: CGFloat) -> Bool { width < CmuxSidebarView.compactBelow }

    /// - Parameters:
    ///   - width: The list's width.
    ///   - searchOpen: The search field edits or holds a query.
    ///   - windowControls: The traffic lights (and the titlebar accessory after them) where they
    ///     lie over the header's band, in its flipped coordinates; nil when the list is clear of them.
    init(width: CGFloat, searchOpen: Bool, windowControls: CGRect? = nil) {
        let width = max(0, width)
        let y = ((Self.band - Self.side) / 2).rounded()
        compact = Self.isCompact(width: width)
        // Messages' header under the lights: the search field on its own row below them.
        let underLights = windowControls.map { ($0.maxY + Self.rowGap).rounded(.up) }
        if compact {
            filter = .zero
            buttonsCovered = searchOpen
            let searchY = underLights ?? y
            search = searchOpen ? CGRect(x: Self.inset, y: searchY, width: max(0, width - 2 * Self.inset), height: Self.side)
                : CGRect(x: Self.inset, y: y, width: 0, height: 0)
            if searchOpen, underLights != nil { listTop = max(Self.band, search.maxY + Self.rowGap) }
            return
        }
        buttonsCovered = false
        if let controls = windowControls, let searchY = underLights {
            let filterX = width - Self.inset - Self.side
            // The toggle at the top row's right end, on the lights' line, when it clears them
            // (a list narrower than the lights and the toggle keeps it on the search row).
            if filterX >= controls.maxX + Self.gap {
                // A circle centred on the lights' line, as tall as fits under the window's top.
                let d = (min(Self.side, 2 * (controls.midY - Self.topMargin)) / 2).rounded(.down) * 2
                filter = CGRect(x: width - Self.inset - d, y: (controls.midY - d / 2).rounded(), width: d, height: d)
                let rowY = max(searchY, (filter.maxY + Self.rowGap).rounded(.up))
                search = CGRect(x: Self.inset, y: rowY, width: max(0, width - 2 * Self.inset), height: Self.side)
            } else {
                let field = max(Self.minimumField, width - 2 * Self.inset - (Self.side + Self.gap))
                search = CGRect(x: Self.inset, y: searchY, width: field, height: Self.side)
                filter = CGRect(x: search.maxX + Self.gap, y: searchY, width: Self.side, height: Self.side)
            }
            listTop = max(Self.band, search.maxY + Self.rowGap)
            return
        }
        let field = max(Self.minimumField, width - 2 * Self.inset - (Self.side + Self.gap))
        search = CGRect(x: Self.inset, y: y, width: field, height: Self.side)
        filter = CGRect(x: search.maxX + Self.gap, y: y, width: Self.side, height: Self.side)
    }
}
