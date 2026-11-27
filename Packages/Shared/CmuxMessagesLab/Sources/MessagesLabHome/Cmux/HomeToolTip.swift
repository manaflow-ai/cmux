// cmux: the host's tooltip for the Home transcript's controls. Not a vendored file.
import AppKit

extension NSView {
    /// cmux: the control's tooltip, through the host's ``MessagesLabHomeHost/showToolTip``; nil or empty: none. Callable
    /// from the transcript's nonisolated controllers (as `toolTip` was); off the main thread it sets nothing.
    func setHomeToolTip(_ text: String?) {
        HomeToolTipSeam(view: self).set(text)
    }
}

extension NSSegmentedControl {
    /// cmux: `texts[i]` as segment `i`'s tooltip, through the host's ``MessagesLabHomeHost/showToolTipRegions``. Each
    /// region is its segment's width (`width(forSegment:)`; 0, AppKit's own size, counts as an even share), and the
    /// room the style leaves between segments (`.separated`'s gaps) is split between its neighbours, so the regions
    /// tile the control. Call it after the control's size changes.
    @MainActor func setHomeSegmentToolTips(_ texts: [String]) {
        let count = segmentCount
        guard count > 0 else { return MessagesLabHomeView.host.showToolTipRegions(self, []) }
        let set = (0..<count).map { width(forSegment: $0) }
        let even = bounds.width / CGFloat(count)
        let widths = set.contains(0) ? Array(repeating: even, count: count) : set
        let gap = count > 1 ? max(0, (bounds.width - widths.reduce(0, +)) / CGFloat(count - 1)) : 0
        var x: CGFloat = 0
        var regions: [(rect: NSRect, text: String)] = []
        for (index, (width, text)) in zip(widths, texts).enumerated() {
            let lead = index == 0 ? 0 : gap / 2, trail = index == count - 1 ? 0 : gap / 2
            regions.append((rect: NSRect(x: x - lead, y: 0, width: width + lead + trail, height: bounds.height), text: text))
            x += width + gap
        }
        MessagesLabHomeView.host.showToolTipRegions(self, regions)
    }
}
