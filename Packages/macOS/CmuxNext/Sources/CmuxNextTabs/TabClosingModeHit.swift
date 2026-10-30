import AppKit

/// Rapid close clicks in Chrome's closing mode (tabs keep their widths after
/// a mouse close until the pointer leaves the strip): the next tab's close
/// button arrives where the last one was. A press there is for that close
/// button even while the tab still slides in, so clicks faster than the slide
/// close one tab each and never select one (cx-ag5.11).
@MainActor
struct TabClosingModeHit {
    /// The last close press: its distance from its tab's trailing edge, and its height in the clip.
    private var anchor: (fromTrailing: CGFloat, y: CGFloat)?

    /// A close button press at clip point `point` on a tab laid out at `frame`.
    mutating func closePressed(at point: CGPoint, on frame: CGRect) {
        anchor = (frame.maxX - point.x, point.y)
    }

    /// The tab whose laid-out frame (where its springs settle, not where it
    /// is mid-slide) puts a close button it shows under the pointer at clip
    /// point `point`. Never a pinned tab or one whose x stays hidden there.
    func tab(at point: CGPoint, in strip: TabStripView) -> TabID? {
        guard let anchor, point.x >= 0, point.x <= strip.tabsClip.bounds.width,
              abs(point.y - anchor.y) <= strip.metrics.closeButtonSize / 2 + 2,
              let hit = Self.laidOut(strip).first(where: { $0.frame.minX <= point.x && point.x < $0.frame.maxX }),
              abs(hit.frame.maxX - point.x - anchor.fromTrailing) <= 4,
              let item = strip.model.tab(hit.id), !item.isPinned, item.isClosable,
              TabChromeVisibility.resolve(width: hit.frame.width, isPinned: false, isSelected: item.id == strip.model.selectedID,
                                          isHovered: true, style: strip.model.style, metrics: strip.metrics).showsClose else { return nil }
        return hit.id
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
