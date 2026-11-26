public import CoreGraphics
import MessagesLabSidebar

/// The Home list's header: search and the Unread toggle on one row, in a band as tall as the
/// transcript's header (Messages' toolbar row). Only the search field's width changes with the
/// list's width. Compose is never in the list: as in Messages it sits at the chat's top-left
/// (`HomeChatColumnView`) at every width (the user, 2026-10-21). The avatar-only list (below
/// `CmuxSidebarView.compactBelow`) is Messages' avatar strip: no search and no filter (the user,
/// 2026-11-24: "lets jus copy how apple does it"). An open search (⌘F, type-to-search) takes a row
/// until it closes. Frames are in the header's flipped coordinates
/// (y down).
///
/// Under the window's traffic lights (the window's sidebar closed, the list at the window's left
/// edge) the header is Messages' (the user, 2026-10-28, "we should just match"): the lights have
/// the top row to themselves with the Unread toggle at its right end on their line, and the
/// search field spans the list on the row under them. Measured on macOS 26 Messages at 2x (the user,
/// 2026-11-23: "EXACTLY like imessage"): the filter is a bare glyph (no glass circle) centred on the
/// lights' line 21.75 pt from the list's right edge, the search field is 36 pt tall, and the list
/// starts 7 pt under it. The field's centre is on the workspace sidebar's Chief row. No New Chief button: New Chief is in
/// compose's right-click menu, the New Message list and the command palette. In the avatar-only list an
/// open search sits under the lights too. Beside the window's sidebar (the lights clear of the
/// list) the header keeps that shape with nothing on the lights' line, so the sidebar's toggle
/// moves the list sideways only (the user, 2026-11-19, msg 42221: "stuff in the home imessage
/// chief ui shifts around too"). Only full screen, with no lights, has the one-row band.
public struct HomeSidebarHeaderLayout: Equatable, Sendable {
    /// The band the row sits in; the list starts under it. One height at every density and text
    /// size: it lines up with the chat's header beside it (`HomeChatColumnView`), and it holds the
    /// biggest filter circle (``HomeSidebarHeaderMetrics/side``, 39 pt at Comfortable, Larger text).
    static let band: CGFloat = 52
    /// The chat column's top row (the traffic lights, Chats and compose; ``band``): a page that fills the
    /// column starts its own top line under it (the New Message page's To: field).
    public static var chatTopRow: CGFloat { band }
    /// The filter circle's least room above it under the traffic lights: cmux's lights sit higher
    /// than Messages', so on their line the circle shrinks rather than run off the window's top.
    static let topMargin: CGFloat = 1
    static let inset: CGFloat = 10
    static let gap: CGFloat = 6
    /// The narrowest search field: its glass and "Search" still show.
    static let minimumField: CGFloat = 72
    /// Where the avatar strip's first row starts: Messages' first avatar is centred 83.25 pt under the panel's top
    /// (measured at 2x), in an 80.5 pt row.
    static let stripListTop: CGFloat = 43
    /// The avatar strip's margin beside its Unread chip (a filter left on in the full list).
    static let edge: CGFloat = 4

    /// The avatar-only list: Messages' strip, no search, filter or compose.
    public private(set) var compact: Bool
    /// The search capsule; zero-sized in the avatar-only list while the search is closed.
    public private(set) var search: CGRect
    /// A search circle: always zero-sized (Messages' avatar strip has none).
    public private(set) var searchIcon: CGRect = .zero
    /// The Unread toggle; zero-sized in the avatar-only list.
    public private(set) var filter: CGRect
    /// The bare filter's glyph size on the lights' line (Messages' 16.5 pt at the standard size),
    /// kept when its box shrinks to fit under the window's top; nil: half the toggle's height.
    public private(set) var filterGlyph: CGFloat?
    /// The list's compose button: always zero-sized (compose is the chat's, `HomeChatColumnView`).
    public private(set) var compose: CGRect = .zero
    /// An open search in the avatar-only list covers the band until it closes.
    public private(set) var buttonsCovered: Bool
    /// Where the list starts: under the band, or under the search row when the traffic lights
    /// take the top row.
    public private(set) var listTop: CGFloat = Self.band
    /// The search row's distance under the traffic lights in the avatar-only list (its circles).
    static let rowGap: CGFloat = 10
    /// The search field's centre under the lights' centre: on the workspace sidebar's Chief row beside
    /// it (the user, 2026-11-23: "align the search bar with the chief"; measured in a tagged build,
    /// the row's centre 38 pt under the lights'). The list's top under the field is Messages'.
    static let searchCenterBelowLights: CGFloat = 38
    static let listGap: CGFloat = 7
    /// Messages: the filter glyph's centre from the list's right edge.
    static let filterCenterFromRight: CGFloat = 21.75
    /// The on filter's chip row (Unread ×) under the search row, while a filter is on (the user,
    /// 2026-11-03, msg 20156: the list said No Results with nothing to show the filter was on);
    /// zero-sized while no filter is on or an open search covers the band. The chip is as wide
    /// as its text, at most this row; its height is ``HomeSidebarHeaderMetrics/chipHeight``.
    public private(set) var filterChip: CGRect = .zero

    /// - Parameters:
    ///   - width: The list's width.
    ///   - searchOpen: The search field edits or holds a query.
    ///   - windowControls: The traffic lights over the band (see the other initializer).
    ///   - filterOn: A filter is on (Unread): its chip row goes under the search row and the list under it.
    ///   - metrics: The header's sizes at the sidebar's density and text size.
    init(width: CGFloat, searchOpen: Bool, windowControls: CGRect? = nil, filterOn: Bool,
         metrics: HomeSidebarHeaderMetrics = .standard) {
        self.init(width: width, searchOpen: searchOpen, windowControls: windowControls, metrics: metrics)
        guard filterOn, !buttonsCovered else { return }
        let inset = compact ? Self.edge : Self.inset
        filterChip = CGRect(x: inset, y: listTop, width: max(0, max(0, width) - 2 * inset), height: metrics.chipHeight)
        listTop = filterChip.maxY + metrics.chipGap
    }

    /// The list at `width` shows avatars only (Messages' strip).
    public static func isCompact(width: CGFloat) -> Bool { width < CmuxSidebarView.compactBelow }

    /// The buttons right of the search field (the Unread toggle).
    static let trailingButtons: CGFloat = 1

    /// `value` on the nearest 2x pixel.
    private static func pixel(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }

    /// - Parameters:
    ///   - width: The list's width.
    ///   - searchOpen: The search field edits or holds a query.
    ///   - windowControls: The traffic lights' row over the header's band (`homeLightsRow`), in its
    ///     flipped coordinates: the lights and the accessory after them as they lie over a list at
    ///     the window's left edge, the same while the list is clear of them; nil with no lights (full screen).
    ///   - metrics: The header's sizes at the sidebar's density and text size.
    init(width: CGFloat, searchOpen: Bool, windowControls: CGRect? = nil, metrics: HomeSidebarHeaderMetrics = .standard) {
        let width = max(0, width)
        // The filter circle's diameter and the search capsule's height (``HomeSidebarHeaderMetrics/side``).
        let side = metrics.side
        let y = ((Self.band - side) / 2).rounded()
        compact = Self.isCompact(width: width)
        // Messages' header under the lights: the search field on its own row below them.
        let underLights = windowControls.map { ($0.maxY + Self.rowGap).rounded(.up) }
        if compact {
            // Messages' avatar strip (macOS 26, the user's recording 2026-11-24: "lets jus copy how apple does it"):
            // no search and no filter, the first row from `stripListTop`. ⌘F or type-to-search still opens the
            // field, on its own row under the lights, until it closes.
            buttonsCovered = searchOpen
            filter = .zero
            listTop = Self.stripListTop
            guard searchOpen else {
                search = CGRect(x: Self.inset, y: y, width: 0, height: 0)
                return
            }
            let fieldHeight = metrics.searchHeight
            let rowY = underLights ?? ((Self.band - fieldHeight) / 2).rounded()
            search = CGRect(x: Self.inset, y: rowY, width: max(0, width - 2 * Self.inset), height: fieldHeight)
            listTop = max(Self.band, search.maxY + Self.rowGap)
            return
        }
        buttonsCovered = false
        // The bare filter's box: its glyph is half of it (`HomeHeaderButton`), 16.5 pt at the
        // standard size as Messages' 33 px glyph.
        let filterSide = (side * 1.1).rounded()
        let fieldHeight = metrics.searchHeight
        if let controls = windowControls {
            // As tall as fits under the window's top.
            let d = min(filterSide, (2 * (controls.midY - Self.topMargin)).rounded(.down))
            let onLine = CGRect(x: Self.pixel(width - Self.filterCenterFromRight - d / 2), y: Self.pixel(controls.midY - d / 2), width: d, height: d)
            let rowY = Self.pixel(controls.midY + Self.searchCenterBelowLights - fieldHeight / 2)
            // The toggle at the top row's right end, on the lights' line, when it clears them. A
            // list narrower than the lights and the toggle keeps the same bare glyph at the same
            // place from the right on the search row instead, and the field ends before it.
            filterGlyph = filterSide / 2
            if onLine.minX >= controls.maxX + Self.gap {
                filter = onLine
                search = CGRect(x: Self.inset, y: rowY, width: max(0, width - 2 * Self.inset), height: fieldHeight)
            } else {
                let box = CGRect(x: onLine.minX, y: Self.pixel(rowY + fieldHeight / 2 - d / 2), width: d, height: d)
                // The field ends at the glyph's box: the box's margin is the gap to the glyph.
                let field = max(Self.minimumField, box.minX - Self.inset)
                search = CGRect(x: Self.inset, y: rowY, width: field, height: fieldHeight)
                filter = box
            }
            listTop = max(Self.band, search.maxY + Self.listGap)
            return
        }
        let fieldY = ((Self.band - fieldHeight) / 2).rounded()
        let field = max(Self.minimumField, width - 2 * Self.inset - Self.trailingButtons * (side + Self.gap))
        search = CGRect(x: Self.inset, y: fieldY, width: field, height: fieldHeight)
        filter = CGRect(x: search.maxX + Self.gap, y: Self.pixel(search.midY - side / 2), width: side, height: side)
    }
}
