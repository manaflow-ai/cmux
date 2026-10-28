public import AppKit
import CmuxNextDesign
import QuartzCore

/// A folded pane (`PaneChromeFit.isCollapsed`; Lawrence 2026-10-28: "a collapsed bar ... that shows the tab's icon
/// or nothing and expands on click or a shortcut"): a bar the size of the pane, over its hidden content. It shows
/// the selected tab's icon when the bar is wide and tall enough, else nothing, and a click opens the pane again
/// (``onExpand``: the pane runs `pane.expandCollapsed`, the action Ctrl-Cmd-X runs). VoiceOver reads it as a
/// button that expands the pane.
public final class CollapsedPaneBarView: NSView {
    /// Opens the pane again.
    public var onExpand: (() -> Void)?
    private let iconLayer = CALayer()
    private var item: TabItem?
    private var pressed = false

    override public init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        iconLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(iconLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Strings.expandFoldedPane)
        setAccessibilityIdentifier("cmux.pane.collapsedBar")
        toolTip = Strings.expandFoldedPane
        applyColors()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }
    override public var mouseDownCanMoveWindow: Bool { false }

    /// Shows `item`'s icon (the pane's selected tab), or nothing.
    public func show(_ item: TabItem?) {
        guard item != self.item else { return }
        self.item = item
        if let item { setAccessibilityHelp(item.title) }
        applyColors()
    }

    override public func layout() {
        super.layout()
        placeIcon()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyColors()
    }

    /// The icon centered when the bar holds it whole; hidden otherwise.
    private func placeIcon() {
        let side = TabStripMetrics.standard.iconSize
        let fits = iconLayer.contents != nil && bounds.width >= side && bounds.height >= side
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconLayer.isHidden = !fits
        let scale = window?.backingScaleFactor ?? 2
        iconLayer.frame = CGRect(x: ((bounds.width - side) / 2 * scale).rounded() / scale, y: ((bounds.height - side) / 2 * scale).rounded() / scale,
                                 width: side, height: side)
        CATransaction.commit()
    }

    /// The pane's content background, opaque (it covers content that keeps the keys), and the icon in the chrome's secondary text color, from the theme.
    private func applyColors() {
        let scale = window?.backingScaleFactor ?? 2
        let side = TabStripMetrics.standard.iconSize
        let (background, image) = performWithTheme {
            (Palette.surfaceBackground.withAlphaComponent(1).cgColor, item?.iconImage(tint: Palette.textSecondary, size: side, scale: scale))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = background
        iconLayer.contents = image
        iconLayer.contentsScale = scale
        CATransaction.commit()
        needsLayout = true // invalidate: the icon came or went (placeIcon shows it only when it has one)
    }

    override public func mouseDown(with event: NSEvent) { pressed = true }

    override public func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onExpand?()
    }

    override public func accessibilityPerformPress() -> Bool {
        onExpand?()
        return onExpand != nil
    }
}
