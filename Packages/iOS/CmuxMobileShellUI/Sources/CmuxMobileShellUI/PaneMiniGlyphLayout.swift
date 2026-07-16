import CoreGraphics
import CmuxMobileShellModel

/// Maps normalized Mac pane geometry into the mini split glyph canvas.
struct PaneMiniGlyphLayout {
    let size: CGSize

    func rect(for pane: MobilePaneNormalizedRect) -> CGRect {
        let x = min(max(CGFloat(pane.x), 0), 1)
        let y = min(max(CGFloat(pane.y), 0), 1)
        let maxWidth = max(0, 1 - x)
        let maxHeight = max(0, 1 - y)
        let width = min(max(CGFloat(pane.w), 0), maxWidth)
        let height = min(max(CGFloat(pane.h), 0), maxHeight)
        return CGRect(
            x: x * size.width,
            y: y * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }
}
