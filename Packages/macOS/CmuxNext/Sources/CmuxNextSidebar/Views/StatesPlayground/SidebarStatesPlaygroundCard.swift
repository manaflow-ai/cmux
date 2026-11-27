import CoreGraphics

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground): the real workspace hover card drawn beside a pinned row,
/// as measured on its laid-out views, in points.
struct SidebarStatesPlaygroundCard {
    /// The card's frame in its cell (top-left origin): the glass panel the hover shows.
    var frame: CGRect
    /// Each tab row's height in the card, top to bottom.
    var tabRowHeights: [CGFloat]

    /// The cell caption: the card's size, its tab rows' heights and the row's height
    /// ("Card 280×164 · tab rows 28, 28 · row 24").
    func sizeText(rowHeight: CGFloat) -> String {
        let rows = tabRowHeights.map { SidebarStatesPlaygroundMark.number($0) }.joined(separator: ", ")
        return String(format: String(localized: "sidebar.statesPlayground.card.caption", defaultValue: "Card %1$@ · tab rows %2$@ · row %3$@",
                                     bundle: .module),
                      SidebarStatesPlaygroundMark.text(frame.size), rows.isEmpty ? "-" : rows, SidebarStatesPlaygroundMark.number(rowHeight))
    }
}
