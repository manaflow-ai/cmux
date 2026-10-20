public import CoreGraphics

/// The Home list's header: search, the Unread toggle and compose on one row at every width, in
/// a band as tall as the transcript's header (Messages' toolbar row). Narrow first: only the
/// search field's width changes. Below the width where the field still fits beside both buttons
/// it becomes a search icon button, and below the width where three buttons fit at their size
/// the buttons shrink. Nothing hides and nothing wraps. An open search (the field edits, or holds
/// a query) on a collapsed row takes the whole row until it closes. Frames are in the header's
/// flipped coordinates (y down).
public struct HomeSidebarHeaderLayout: Equatable, Sendable {
    /// The band the row sits in; the list starts under it.
    static let band: CGFloat = 52
    /// The buttons' and the field's height (the field is a capsule of this height).
    static let side: CGFloat = 28
    static let inset: CGFloat = 10
    static let gap: CGFloat = 6
    /// The narrowest search field: its glass and "Search" still show.
    static let minimumField: CGFloat = 72
    /// Three buttons below their full size: the tightest margins, and the smallest button.
    static let tightInset: CGFloat = 4
    static let tightGap: CGFloat = 2
    static let minimumSide: CGFloat = 16

    /// The search capsule; zero-sized while the search is an icon and closed.
    public private(set) var search: CGRect
    /// The search icon button while the field does not fit (nil: the field shows).
    public private(set) var searchButton: CGRect?
    public private(set) var filter: CGRect
    public private(set) var compose: CGRect
    /// An open search covers the row (collapsed only): the buttons are hidden until it closes.
    public private(set) var buttonsCovered: Bool
    /// Where the list starts.
    public var listTop: CGFloat { Self.band }

    /// The search field fits beside both buttons at this width.
    static func fieldFits(width: CGFloat) -> Bool {
        width - 2 * inset - 2 * (side + gap) >= minimumField
    }

    init(width: CGFloat, searchOpen: Bool) {
        let width = max(0, width)
        let field = width - 2 * Self.inset - 2 * (Self.side + Self.gap)
        if field >= Self.minimumField {
            let y = ((Self.band - Self.side) / 2).rounded()
            search = CGRect(x: Self.inset, y: y, width: field, height: Self.side)
            filter = CGRect(x: search.maxX + Self.gap, y: y, width: Self.side, height: Self.side)
            compose = CGRect(x: filter.maxX + Self.gap, y: y, width: Self.side, height: Self.side)
            searchButton = nil
            buttonsCovered = false
            return
        }
        // Three buttons: at full size while they fit, else as large as the width allows.
        let full = 3 * Self.side + 2 * Self.gap + 2 * Self.inset
        let inset = width >= full ? Self.inset : Self.tightInset
        let gap = width >= full ? Self.gap : Self.tightGap
        let side = width >= full ? Self.side : max(Self.minimumSide, ((width - 2 * inset - 2 * gap) / 3).rounded(.down))
        let y = ((Self.band - side) / 2).rounded()
        compose = CGRect(x: width - inset - side, y: y, width: side, height: side)
        filter = CGRect(x: compose.minX - gap - side, y: y, width: side, height: side)
        let button = CGRect(x: inset, y: y, width: side, height: side)
        searchButton = button
        buttonsCovered = searchOpen
        search = searchOpen ? CGRect(x: inset, y: y, width: max(0, width - 2 * inset), height: side) : CGRect(origin: button.origin, size: .zero)
    }
}
