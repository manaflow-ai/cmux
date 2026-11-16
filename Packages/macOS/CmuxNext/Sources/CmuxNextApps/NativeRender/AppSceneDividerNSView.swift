import AppKit
import CmuxNextDesign

/// `Divider`: a one-pixel hairline in the separator color across the width.
final class AppSceneDividerNSView: AppSceneNodeNSView {
    override func contentHeight(width: CGFloat) -> CGFloat { 1 / max(1, window?.backingScaleFactor ?? 2) }

    override func paint() {
        performWithTheme { layer?.backgroundColor = Palette.separator.cgColor }
    }
}
