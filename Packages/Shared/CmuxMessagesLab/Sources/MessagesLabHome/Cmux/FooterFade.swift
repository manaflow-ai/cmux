import AppKit

/// cmux-classic (v3f k1, "bottom bleed"): the band under the compose field. Rows scrolled beneath the
/// field showed through its glass and the strip under it (a blue bubble under the composer); Messages
/// hides them. The band is the host's colour (Chief: the header band's colour and alpha), clear
/// `FooterFadeView.fadeLength` points above the field's top and solid from the field's top to the
/// pane's bottom. It shows only while a row lies under the field (the transcript is scrolled up from
/// its newest row), so a pinned transcript over a background image looks as before. Takes no clicks.
final class FooterFadeView: NSView {
    /// The fading part above the field's top.
    static let fadeLength: CGFloat = 12

    private(set) var color: NSColor?
    private(set) var maxAlpha: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The band's colour and strongest alpha (nil: no band).
    func setFill(_ color: NSColor?, maxAlpha: CGFloat) {
        self.color = color
        self.maxAlpha = maxAlpha
        needsDisplay = true
    }

    /// Where the band goes in a pane of `bounds` whose field starts at `fieldTop` (pure, for tests).
    static func frame(fieldTop: CGFloat, in bounds: CGRect) -> CGRect {
        let top = max(bounds.minY, min(fieldTop, bounds.maxY) - fadeLength)
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top))
    }

    /// Whether the band shows: a row lies under the field when the transcript's offset is short of
    /// its pinned offset (the newest row sits on the field when they are equal). Pure, for tests.
    static func revealed(hasFill: Bool, offset: CGFloat, pinnedOffset: CGFloat) -> Bool {
        guard hasFill, offset.isFinite, pinnedOffset.isFinite else { return false }
        return offset < pinnedOffset - 0.5
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let color, bounds.height > 0 else { return }
        let solid = color.withAlphaComponent(maxAlpha)
        let fade = min(1, Self.fadeLength / bounds.height)
        guard let gradient = NSGradient(colorsAndLocations: (color.withAlphaComponent(0), 0), (solid, fade), (solid, 1)) else { return }
        // Flipped: from the band's top (clear) down to the pane's bottom (solid).
        gradient.draw(from: CGPoint(x: bounds.midX, y: bounds.minY), to: CGPoint(x: bounds.midX, y: bounds.maxY), options: [])
    }

    /// Shows or hides the band (at once: it follows the scroll).
    func setRevealed(_ revealed: Bool) {
        let target: CGFloat = revealed ? 1 : 0
        guard alphaValue != target else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        alphaValue = target
        CATransaction.commit()
    }

    var isRevealed: Bool { alphaValue > 0 }
}

extension HostView {
    /// The footer band follows the field and the rows (called with the header's band after every
    /// layout, engine change and scroll).
    func applyFooterFade() {
        guard let demo else { return }
        let place = FooterFadeView.frame(fieldTop: demo.fieldTop, in: bounds)
        if footerFade.frame != place { footerFade.frame = place }
        footerFade.setRevealed(FooterFadeView.revealed(hasFill: footerFade.color != nil, offset: demo.collection.contentOffset.y,
                                                       pinnedOffset: demo.pinnedOffset))
    }
}

extension MessagesLabHomeView {
    /// cmux-classic: the band under the compose field over rows scrolled beneath it, in `color` at
    /// `maxAlpha` (nil: none). Chief passes its header band's colour and alpha.
    public func setFooterFade(color: NSColor?, maxAlpha: CGFloat) {
        controller.host.footerFade.setFill(color, maxAlpha: maxAlpha)
        controller.host.applyFooterFade()
    }

    /// Whether the footer band shows (a row lies under the field).
    public var footerFadeShown: Bool { controller.host.footerFade.isRevealed }

    /// cmux-classic: room under the newest row for a line the host draws over the transcript's bottom
    /// edge (Chief's "Working · Ns"); 0: none.
    public var transcriptBottomInset: CGFloat {
        get { controller.transcriptBottomInset }
        set { controller.transcriptBottomInset = newValue }
    }
}
