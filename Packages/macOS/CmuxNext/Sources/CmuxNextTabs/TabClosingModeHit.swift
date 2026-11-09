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
    /// Each tab's own hovered close span decides, not the last press's offset:
    /// a tab whose status gives the x its icon's centered slot draws its x
    /// elsewhere than a neighbor without one (#36837).
    func tab(at point: CGPoint, in strip: TabStripView) -> TabID? {
        guard let anchorY, point.x >= 0, point.x <= strip.tabsClip.bounds.width,
              abs(point.y - anchorY) <= strip.metrics.closeButtonSize / 2 + 2,
              let hit = Self.laidOut(strip).first(where: { $0.frame.minX <= point.x && point.x < $0.frame.maxX }),
              let item = strip.model.tab(hit.id), !item.isPinned, item.isClosable,
              let span = Self.hoveredCloseSpan(of: item, at: hit.frame, in: strip),
              span.lowerBound - 2 <= point.x, point.x <= span.upperBound + 2 else { return nil }
        return hit.id
    }

    /// Where tab `item`, laid out at clip frame `frame`, draws its x across while hovered (clip x, the
    /// press's height decides the rest); nil when hovering shows no x. The pill starts at the slot's leading edge.
    static func hoveredCloseSpan(of item: TabItem, at frame: CGRect, in strip: TabStripView) -> ClosedRange<CGFloat>? {
        let m = strip.metrics
        let form = TabChromeVisibility.resolve(
            width: frame.width, isPinned: item.isPinned, isSelected: item.id == strip.model.selectedID, isHovered: true,
            isClosable: item.isClosable, hasStatus: strip.cells[item.id]?.hasStatusMark ?? false, style: strip.model.style, metrics: m)
        guard let x = form.closeButtonOriginX(pillWidth: m.pillFrame(slotWidth: frame.width, height: frame.height).width, metrics: m) else { return nil }
        return (frame.minX + x)...(frame.minX + x + m.closeButtonSize)
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
