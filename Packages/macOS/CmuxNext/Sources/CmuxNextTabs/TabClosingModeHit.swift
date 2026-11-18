import AppKit

/// Rapid close clicks in Chrome's closing mode (tabs keep their widths after
/// a mouse close until the pointer leaves the strip): the next tab's close
/// button arrives where the last one was. A press there is for that close
/// button even while the tab still slides in, so clicks faster than the slide
/// close one tab each and never select one (cx-ag5.11).
@MainActor
struct TabClosingModeHit {
    /// The last close press's height in the clip.
    private var anchorY: CGFloat?

    /// A close button press at clip point `point`.
    mutating func closePressed(at point: CGPoint) {
        anchorY = point.y
    }

    /// The tab whose laid-out frame (where its springs settle, not where it
    /// is mid-slide) puts a close button it shows under the pointer at clip
    /// point `point`. Never a pinned tab or one whose x stays hidden there.
    /// Each tab's own hovered close target decides, not the last press's offset:
    /// a tab whose status gives the x its icon's centered slot draws its x
    /// elsewhere than a neighbor without one (#36837).
    func tab(at point: CGPoint, in strip: TabStripView) -> TabID? {
        guard let anchorY, point.x >= 0, point.x <= strip.tabsClip.bounds.width,
              abs(point.y - anchorY) <= Self.slack(strip.metrics) + strip.metrics.closeButtonSize / 2,
              let hit = Self.laidOut(strip).first(where: { $0.frame.minX <= point.x && point.x < $0.frame.maxX }),
              let item = strip.model.tab(hit.id), !item.isPinned, item.isClosable,
              let target = Self.hoveredCloseTarget(of: item, at: hit.frame, in: strip),
              target.minX <= point.x, point.x < target.maxX else { return nil }
        return hit.id
    }

    /// The x range a hovered click on tab `item`, laid out at clip frame `frame`, closes it in: its drawn x as the
    /// cell draws it (cell edges and x pixel-aligned) grown to the click target (``TabStripMetrics/closeHitRect(_:)``),
    /// the rect `TabStripView.isInCloseButton` tests. Half-open, as `CGRect.contains` is, so closing mode's next close
    /// and a hovered click agree on every point, the target's trailing edge too. nil when hovering shows no x.
    static func hoveredCloseTarget(of item: TabItem, at frame: CGRect, in strip: TabStripView) -> CGRect? {
        let m = strip.metrics
        let scale = strip.window?.backingScaleFactor ?? 2
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = pixel(frame.minX), width = pixel(frame.maxX) - minX
        let form = TabChromeVisibility.resolve(
            width: width, isPinned: item.isPinned, isSelected: item.id == strip.model.selectedID, isHovered: true,
            isClosable: item.isClosable, hasStatus: strip.cells[item.id]?.hasStatusMark ?? false, style: strip.model.style, metrics: m)
        let pill = m.pillFrame(slotWidth: width, height: frame.height)
        guard let x = form.closeButtonOriginX(pillWidth: pill.width, metrics: m) else { return nil }
        let side = m.closeButtonSize
        let drawn = CGRect(x: minX + pixel(x), y: frame.minY + pixel(pill.height / 2 - side / 2), width: side, height: side)
        return m.closeHitRect(drawn)
    }

    /// The slack around the x a click still closes in: the x's hit rect beyond its square (``TabStripMetrics/closeHitRect(_:)``).
    static func slack(_ m: TabStripMetrics) -> CGFloat {
        let side = m.closeButtonSize
        return (m.closeHitRect(CGRect(x: 0, y: 0, width: side, height: side)).width - side) / 2
    }

    /// The strip's shown tabs' frames in its clip once their springs settle.
    static func laidOut(_ strip: TabStripView) -> [(id: TabID, frame: CGRect)] {
        let mapping = strip.scrollMapping(offset: strip.scrollOffset)
        return strip.displayed.compactMap { item in
            guard let place = strip.placed[item.id], place.width > 0.5 else { return nil }
            let height = strip.tabsClip.bounds.height
            return (item.id, CGRect(x: mapping.viewX(place.x, isPinned: item.isPinned), y: 0, width: place.width, height: height))
        }
    }
}
