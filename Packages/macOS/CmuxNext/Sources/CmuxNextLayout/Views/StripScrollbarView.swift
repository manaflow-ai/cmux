import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import QuartzCore

/// The thin scrollbar under the column strip (dock-column.md, B1 to B5):
/// a neutral thumb showing the visible range, no track color. Dragging the
/// thumb scrolls, a click beside it pages. `auto` fades it in while the
/// strip scrolls or the pointer is over it and out after a one-shot
/// deadline; `always` keeps it while columns overflow; `off` hides it.
/// It takes the mouse only while shown, so clicks pass to the panes below.
final class StripScrollbarView: NSView {
    struct Input: Equatable {
        var mode: StripScrollbarMode
        /// The track in this view's superview, full hit band height.
        var band: CGRect
        var offset: CGFloat
        var contentWidth: CGFloat
        var viewportWidth: CGFloat
        var snaps: [CGFloat]
    }

    /// Thumb drag lifecycle and track clicks, in strip offsets.
    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onPage: ((CGFloat) -> Void)?

    private let thumb = CALayer()
    private(set) var thumbRect: CGRect?
    private var input: Input?
    private var trackingArea: NSTrackingArea?
    private(set) var isHovered = false
    private var drag: (grab: CGFloat, width: CGFloat)?
    private(set) var isShown = false
    private let hideTimer: DemandTimer

    /// Idle time before `auto` fades out.
    static let idleDelay: Duration = .milliseconds(1200)

    /// `hideClock` runs the `auto` fade-out deadline.
    init(hideClock: any Clock<Duration>) {
        hideTimer = DemandTimer(owner: "Layout.stripScrollbar.hide", clock: hideClock)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(thumb)
        thumb.opacity = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollBar)
        setAccessibilityLabel(LayoutStrings.stripScrollbarAccessibility)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Thumb thickness and the track inset from the band's bottom.
    static var thickness: CGFloat { Metrics.space2 }
    static var hoverThickness: CGFloat { Metrics.space3 }
    /// The band that takes the mouse while shown.
    static var bandHeight: CGFloat { Metrics.space5 }
    static var minimumThumbWidth: CGFloat { Metrics.space6 * 2 }

    /// New geometry or offset. `scrolled` is true when the offset moved
    /// (any cause): `auto` flashes the thumb.
    func update(_ input: Input, scrolled: Bool) {
        let previous = self.input
        self.input = input
        if frame != input.band { frame = input.band }
        let track = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        thumbRect = StripScrollbarGeometry.thumb(track: track, offset: input.offset, contentWidth: input.contentWidth,
                                                 viewportWidth: input.viewportWidth, minimumThumbWidth: Self.minimumThumbWidth)
        layoutThumb()
        switch input.mode {
        case .off:
            setShown(false)
        case .always:
            setShown(thumbRect != nil)
        case .auto:
            if thumbRect == nil {
                setShown(false)
            } else if scrolled || isHovered || drag != nil || (previous?.mode != .auto && previous != nil) {
                flash()
            }
        }
    }

    private func layoutThumb() {
        guard let rect = thumbRect else { return }
        let thickness = isHovered || drag != nil ? Self.hoverThickness : Self.thickness
        let frame = CGRect(x: rect.minX, y: bounds.height - thickness - Metrics.space1, width: rect.width, height: thickness)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.frame = frame
        thumb.cornerRadius = thickness / 2
        CATransaction.commit()
    }

    /// Shows the thumb and schedules the `auto` fade-out.
    private func flash() {
        setShown(true)
        guard input?.mode == .auto, !isHovered, drag == nil else {
            hideTimer.cancel()
            return
        }
        hideTimer.schedule(after: Self.idleDelay) { @MainActor [weak self] in
            guard let self, self.input?.mode == .auto, !self.isHovered, self.drag == nil else { return }
            self.setShown(false)
        }
    }

    private func setShown(_ shown: Bool) {
        if !shown { hideTimer.cancel() }
        guard shown != isShown else { return }
        isShown = shown
        applyColors()
        let value: Float = shown ? 1 : 0
        thumb.opacity = value
        _ = Motion.set(thumb, "opacity", to: value, fade: shown ? .fadeIn : .fadeOut, from: shown ? Float(0) : Float(1))
    }

    private func applyColors() {
        performWithTheme {
            thumb.backgroundColor = Palette.textTertiary.withAlphaComponent(isHovered || drag != nil ? 0.7 : 0.5).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShown, thumbRect != nil, !isHidden else { return nil }
        return super.hitTest(point)
    }

    /// A click on a window that is not key still scrolls, like a divider.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard thumbRect != nil, input?.mode != .off else { return }
        isHovered = true
        layoutThumb()
        flash()
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layoutThumb()
        applyColors()
        if drag == nil, isShown { flash() }
    }

    override func mouseDown(with event: NSEvent) {
        guard let thumbRect, let input else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if x >= thumbRect.minX, x <= thumbRect.maxX {
            drag = (x - thumbRect.minX, thumbRect.width)
            hideTimer.cancel()
            layoutThumb()
            applyColors()
            onDragBegan?()
        } else if let target = StripScrollbarGeometry.pageTarget(clickX: x, thumb: thumbRect, offset: input.offset,
                                                                viewportWidth: input.viewportWidth, snaps: input.snaps) {
            onPage?(target)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let input else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let maxOffset = ColumnStripGeometry.maxOffset(contentWidth: input.contentWidth, viewportWidth: input.viewportWidth)
        let offset = StripScrollbarGeometry.offset(forThumbMinX: x - drag.grab, thumbWidth: drag.width, track: bounds, maxOffset: maxOffset)
        onDrag?(offset)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        layoutThumb()
        applyColors()
        onDragEnded?()
        flash()
    }
}
