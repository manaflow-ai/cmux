import AppKit
import CmuxNextDesign

/// DEV and NIGHTLY (the Debug menu): a pane's tab bar as the app lays it out: the real ``TabStripView``, an optional
/// control after it (a playground variant's new-tab control) and the real ``PaneToolbarView`` (⋮)
/// at the trailing end. The strip takes the width the controls leave.
final class TabBarPlaygroundBar: NSView {
    let strip: TabStripView
    let trailing: PaneToolbarView?
    private let accessory: NSView?
    private let accessoryWidth: CGFloat

    /// - Parameters:
    ///   - strip: the strip, already configured (metrics, + options).
    ///   - accessory: a variant's own control after the strip, `accessoryWidth` wide.
    ///   - showsMore: whether the pane's ⋮ shows.
    init(strip: TabStripView, accessory: NSView? = nil, accessoryWidth: CGFloat = 0, showsMore: Bool = true) {
        self.strip = strip
        self.accessory = accessory
        self.accessoryWidth = accessoryWidth
        trailing = showsMore ? PaneToolbarView(frame: .zero) : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: TabStripView.preferredHeight))
        wantsLayer = true
        strip.dragsWindowFromEmptySpace = false
        for view in [strip, accessory, trailing].compactMap({ $0 }) { addSubview(view) }
        trailing?.show(more: true, lit: false)
        // The playground shows the controls at rest as a crowded bar does.
        trailing?.alphaValue = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: TabStripView.preferredHeight) }

    override func layout() {
        super.layout()
        let height = bounds.height
        let trailingWidth = trailing.map { max($0.intrinsicContentSize.width, 0) } ?? 0
        trailing?.frame = NSRect(x: bounds.width - trailingWidth, y: 0, width: trailingWidth, height: height)
        accessory?.frame = NSRect(x: bounds.width - trailingWidth - accessoryWidth, y: 0, width: accessoryWidth, height: height)
        strip.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - trailingWidth - accessoryWidth), height: height)
    }
}
