#if DEBUG
import AppKit

/// DEBUG ONLY: the Before/After table playground's window content: the variant picker and the look switch
/// along the top, the live variant (``HomeCompareTablePlayground``) under them.
@MainActor
final class HomeComparePlaygroundContent: NSView {
    weak var picker: NSSegmentedControl?
    weak var appearanceSwitch: NSSegmentedControl?
    weak var stage: NSView?
    /// The playground this window shows (the window keeps it; ``HomeCompareTablePlayground/show(variant:row:dark:)``
    /// finds it through the window).
    var owner: HomeCompareTablePlayground?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let p = picker?.fittingSize ?? .zero, a = appearanceSwitch?.fittingSize ?? .zero
        picker?.frame = CGRect(x: 16, y: 12, width: p.width, height: p.height)
        appearanceSwitch?.frame = CGRect(x: bounds.maxX - 16 - a.width, y: 12, width: a.width, height: a.height)
        let top = 12 + max(p.height, a.height) + 8
        stage?.frame = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
    }
}
#endif
