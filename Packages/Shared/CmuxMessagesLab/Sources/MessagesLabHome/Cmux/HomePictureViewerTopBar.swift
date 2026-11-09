import CoreGraphics

/// cmux: where the picture viewer's top bar puts its pieces (the user, 2026-11-06, msg 23681: the chat's round
/// compose button sat on the title, so "Dark · After" read "k · After"). The title starts after any control the
/// pane floats over the bar's left half and the close button and counter end before any over its right half;
/// the Light | Dark switch stays centred unless the title needs the room, and the title gets only the space
/// left before the switch (or the counter), truncating rather than running under it. Frames are in the
/// viewer's flipped coordinates; a piece that does not fit gets an empty frame.
struct HomePictureViewerTopBar: Equatable {
    /// The bar's height: the picture area starts below it.
    static let height: CGFloat = 44
    /// The title's left inset when nothing floats over the bar.
    static let inset: CGFloat = 16
    /// The space between two pieces, and between a piece and a floating control.
    static let gap: CGFloat = 10
    /// The close button's side and its inset from the right edge.
    static let closeSide: CGFloat = 26
    static let closeInset: CGFloat = 12

    var title: CGRect
    var center: CGRect
    var counter: CGRect
    var close: CGRect

    /// The bar of a viewer `width` wide.
    ///
    /// - Parameters:
    ///   - width: The viewer's width.
    ///   - titleWidth: The title's natural width; 0 for no title.
    ///   - titleHeight: The title's height.
    ///   - center: The Light | Dark switch's size; zero when it is hidden.
    ///   - counterWidth: The counter's natural width ("4 of 4"); 0 for no counter.
    ///   - obstacles: Controls drawn over the viewer (in its coordinates); only those reaching into the bar count.
    init(width: CGFloat, titleWidth: CGFloat, titleHeight: CGFloat = 18, center: CGSize, counterWidth: CGFloat,
         avoiding obstacles: [CGRect]) {
        let band = CGRect(x: 0, y: 0, width: width, height: Self.height)
        var lead = Self.inset
        var trail = width - Self.closeInset
        for obstacle in obstacles {
            let o = obstacle.intersection(band)
            guard !o.isNull, !o.isEmpty else { continue }
            if o.midX < width / 2 { lead = max(lead, (o.maxX + Self.gap).rounded(.up)) } else { trail = min(trail, (o.minX - Self.gap).rounded(.down)) }
        }
        close = CGRect(x: trail - Self.closeSide, y: ((Self.height - Self.closeSide) / 2).rounded(), width: Self.closeSide, height: Self.closeSide)
        var right = close.minX - Self.gap
        counter = .zero
        if counterWidth > 0, right - counterWidth >= lead {
            counter = CGRect(x: right - counterWidth, y: ((Self.height - 16) / 2).rounded(), width: counterWidth, height: 16)
            right = counter.minX - Self.gap
        }
        self.center = .zero
        if center.width > 0, right - lead >= center.width {
            // Centred, moved right only as far as the whole title needs and the counter allows.
            let wanted = titleWidth > 0 ? lead + titleWidth + Self.gap : lead
            let x = max(lead, min(max(((width - center.width) / 2).rounded(), wanted), right - center.width))
            self.center = CGRect(x: x, y: ((Self.height - center.height) / 2).rounded(), width: center.width, height: center.height)
            right = x - Self.gap
        }
        let room = max(0, min(titleWidth, right - lead))
        title = room > 0 ? CGRect(x: lead, y: ((Self.height - titleHeight) / 2).rounded(), width: room, height: titleHeight) : .zero
    }
}
