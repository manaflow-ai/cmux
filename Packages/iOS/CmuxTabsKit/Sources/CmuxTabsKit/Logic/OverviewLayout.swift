import CoreGraphics

/// Tab overview grid geometry (Mobile Safari, device-measured on an
/// iPhone 17 Pro Max): two columns with 16 pt insets and gutter, card
/// aspect 1.408, 23 pt title row, 16 pt between rows, first row 60 pt below
/// the safe area, 48 pt bottom bar 38 pt above the screen bottom.
///
/// Content coordinates are the grid's scroll content; screen coordinates
/// are content minus the scroll offset (the grid fills the screen).
struct OverviewLayout: Equatable, Sendable {
    var size: CGSize
    var safeTop: CGFloat
    var safeBottom: CGFloat
    var count: Int
    /// The first `pinned` items are pinned: Safari shows them as capsules
    /// (177 x 30, two per row, 16 pt apart) above the grid.
    var pinned: Int = 0

    static let pinnedHeight: CGFloat = 30

    static let gridInset: CGFloat = 16
    static let titleRow: CGFloat = 23
    static let rowGap: CGFloat = 16
    static let cardAspect: CGFloat = 249.3 / 177.0
    /// 15.2 pt at 196 pt wide on an iPhone 17 Pro Max device screenshot
    /// (continuous corner fitted to the edge profile); scaled with the card.
    static let baseCardRadius: CGFloat = 13.7
    static let control: CGFloat = 48

    /// A lone tab: Safari shows one larger card, centred (device: 294.7 pt
    /// wide at x 72.7 on a 440 pt iPhone 17 Pro Max, top 124; simulator:
    /// 268 pt at x 66.7 on 402, top 122), with the same aspect, close button
    /// insets and title row, and "1 Tab" in the bar.
    var isLone: Bool { count - pinned == 1 }

    /// Two-column card width: 177 pt on a 402 pt screen, 196 pt on 440.
    var columnWidth: CGFloat { ((size.width - 3 * Self.gridInset) / 2).rounded(.down) }
    /// The card width: two thirds of the screen for a lone tab, else the
    /// column width.
    var cardWidth: CGFloat { isLone ? (size.width * 2 / 3).rounded() : columnWidth }
    var cardHeight: CGFloat { cardWidth * Self.cardAspect }
    /// Page points (from the page's top) a card shows.
    var cardPageHeight: CGFloat { size.width * Self.cardAspect }

    /// How far a rect `width` wide is from full screen (0) to a grid card
    /// (1): a card's content anchor moves with the zoom, so it never jumps.
    func cardAnchorFraction(_ width: CGFloat) -> CGFloat {
        guard size.width > cardWidth, cardWidth > 0 else { return 0 }
        return min(1, max(0, (size.width - width) / (size.width - cardWidth)))
    }
    /// 18 pt at 177 pt wide, scaled with the card.
    var cardRadius: CGFloat { Self.baseCardRadius * cardWidth / 177 }
    var pitch: CGFloat { cardHeight + Self.titleRow + Self.rowGap }
    /// Card top of the first row (122 on a 62 pt safe area).
    var top: CGFloat { pinnedTop + CGFloat(pinnedRows) * (Self.pinnedHeight + Self.rowGap) }
    /// The pinned area's first row (where the grid starts without pins).
    var pinnedTop: CGFloat { safeTop + 60 }
    var pinnedRows: Int { (pinned + 1) / 2 }
    var barRect: CGRect {
        let bottom = size.height - max(safeBottom, 20) - 4
        return CGRect(x: 0, y: bottom - Self.control, width: size.width, height: Self.control)
    }
    var bottomPadding: CGFloat { size.height - barRect.minY + 12 }
    var rows: Int { (count - pinned + 1) / 2 }
    var contentHeight: CGFloat { top + CGFloat(rows) * pitch - Self.rowGap + bottomPadding }
    var maxOffset: CGFloat { max(0, contentHeight - size.height) }

    /// Card frame in content coordinates.
    func card(_ index: Int) -> CGRect {
        if index < pinned {
            let col = index % 2, row = index / 2
            let x = col == 0 ? Self.gridInset : size.width - Self.gridInset - columnWidth
            return CGRect(x: x, y: pinnedTop + CGFloat(row) * (Self.pinnedHeight + Self.rowGap), width: columnWidth, height: Self.pinnedHeight)
        }
        let index = index - pinned
        if isLone, index == 0 {
            return CGRect(x: (size.width - cardWidth) / 2, y: top, width: cardWidth, height: cardHeight)
        }
        let col = index % 2, row = index / 2
        let x = col == 0 ? Self.gridInset : size.width - Self.gridInset - cardWidth
        return CGRect(x: x, y: top + CGFloat(row) * pitch, width: cardWidth, height: cardHeight)
    }

    /// Card frame on screen at scroll `offset` (may lie partly or wholly off screen).
    func screenFrame(_ index: Int, offset: CGFloat) -> CGRect {
        card(index).offsetBy(dx: 0, dy: -offset)
    }

    /// The tab zoom's card end: the card's content frame converted to the
    /// screen through the grid content's origin in screen coordinates
    /// (x 0, y = -scroll offset when the grid fills the screen).
    /// The card slot under `point` (grid content coordinates), counting
    /// the gaps around a card as that card; nil outside every slot.
    func slot(at point: CGPoint) -> Int? {
        (0..<count).first { card($0).insetBy(dx: -8, dy: -16).contains(point) }
    }

    func zoomEndpoint(_ index: Int, contentOrigin: CGPoint?, fallbackOffset: CGFloat) -> CGRect {
        let origin = contentOrigin ?? CGPoint(x: 0, y: -fallbackOffset)
        return card(index).offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Whether the card and its title row are fully on screen between the
    /// top controls and the bottom bar.
    func isFullyVisible(_ index: Int, offset: CGFloat) -> Bool {
        let r = screenFrame(index, offset: offset)
        return r.minY >= safeTop + 40 && r.maxY + Self.titleRow <= barRect.minY
    }

    /// Scroll offset before zooming a page into card `index` (page -> grid,
    /// pinch-in), measured on safari-scroll-into-view-device.mp4: a card
    /// already fully visible keeps the current offset; otherwise the grid
    /// scrolls so the card sits where the first row does (its top at
    /// `top`), clamped to the content. Both recorded cases (index 5 and 6 of
    /// 7 from offset 0) landed on 508 = the clamped value; aligning the card
    /// bottom just above the bar would have given 193.
    func offset(revealing index: Int, from current: CGFloat) -> CGFloat {
        let clamped = min(maxOffset, max(0, current))
        if isFullyVisible(index, offset: clamped) { return clamped }
        return min(maxOffset, max(0, card(index).minY - top))
    }
}


/// Which grid cards are built (in the view tree), as a collection view keeps
/// only the cells near the screen: a card costs a full page of content laid
/// out and scaled, so a grid of 80 tabs never builds 80.
///
/// Bands are in screens around the visible rect: cards on screen are needed
/// at once, cards within `keep` screens are built ahead one per frame (the
/// nearest first), and a built card is released only past `release`
/// screens, so scrolling back and forth does not build a card again.
struct CardResidencyPlan: Equatable, Sendable {
    var keep: CGFloat = 3
    var release: CGFloat = 4

    /// What to change for the grid at scroll `offset` with `built` cards.
    struct Step: Equatable, Sendable {
        /// Unbuilt cards on screen (build now when the grid must show them).
        var visible: [Int] = []
        /// The nearest unbuilt card within the keep band (build next).
        var next: Int?
        /// Built cards past the release band.
        var release: [Int] = []
    }

    func step(layout: OverviewLayout, offset: CGFloat, isBuilt: (Int) -> Bool) -> Step {
        let h = layout.size.height
        let top = max(0, offset)
        let screen = (min: top, max: top + h)
        var step = Step()
        var best: (index: Int, distance: CGFloat)?
        for i in 0..<layout.count {
            let r = layout.card(i)
            let minY = r.minY, maxY = r.maxY + OverviewLayout.titleRow
            let distance = maxY < screen.min ? screen.min - maxY : minY > screen.max ? minY - screen.max : 0
            let built = isBuilt(i)
            if built {
                if distance > release * h { step.release.append(i) }
            } else if distance == 0 {
                step.visible.append(i)
            } else if distance <= keep * h, distance < (best?.distance ?? .infinity) {
                best = (i, distance)
            }
        }
        step.next = step.visible.first ?? best?.index
        return step
    }
}
