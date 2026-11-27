import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): a pane's tab bar as the app lays it out: the real ``TabStripView`` and an
/// optional control after it (a playground variant's new-tab control). The strip takes the width the control
/// leaves; like the shipped bar, nothing else sits at the trailing end (the pane's "…" is gone, user 2026-11-13).
final class TabBarPlaygroundBar: NSView {
    let strip: TabStripView
    private let accessory: NSView?
    private let accessoryWidth: CGFloat

    /// - Parameters:
    ///   - strip: the strip, already configured (metrics, + options).
    ///   - accessory: a variant's own control after the strip, `accessoryWidth` wide.
    init(strip: TabStripView, accessory: NSView? = nil, accessoryWidth: CGFloat = 0) {
        self.strip = strip
        self.accessory = accessory
        self.accessoryWidth = accessoryWidth
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: TabStripView.preferredHeight))
        wantsLayer = true
        strip.dragsWindowFromEmptySpace = false
        for view in [strip, accessory].compactMap({ $0 }) { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: TabStripView.preferredHeight) }

    override func layout() {
        super.layout()
        let height = bounds.height
        accessory?.frame = NSRect(x: bounds.width - accessoryWidth, y: 0, width: accessoryWidth, height: height)
        strip.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - accessoryWidth), height: height)
    }
}
