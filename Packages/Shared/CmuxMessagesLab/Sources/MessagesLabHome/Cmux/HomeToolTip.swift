// cmux: the host's tooltip for the Home transcript's controls. Not a vendored file.
import AppKit

extension NSView {
    /// cmux: the control's tooltip, through the host's ``MessagesLabHomeHost/toolTip``; nil or empty: none.
    @MainActor func setHomeToolTip(_ text: String?) {
        MessagesLabHomeView.host.toolTip(self, text?.isEmpty == false ? text : nil)
    }
}

extension NSSegmentedControl {
    /// cmux: `texts[i]` as segment `i`'s tooltip, through the host's ``MessagesLabHomeHost/toolTipRegions``. The
    /// segments are taken as equally wide (the transcript's segmented controls give every segment one width), so call
    /// it after the control's size changes.
    @MainActor func setHomeSegmentToolTips(_ texts: [String]) {
        let count = max(1, segmentCount)
        let width = bounds.width / CGFloat(count)
        let regions = texts.prefix(count).enumerated().map { index, text in
            (rect: NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height), text: text)
        }
        MessagesLabHomeView.host.toolTipRegions(self, regions)
    }
}
