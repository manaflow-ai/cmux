import AppKit
import CmuxFoundation
import SwiftUI

/// Button cell that centres its image on the bounds exactly. AppKit's default
/// image rect for a borderless button sits a point off, which shows the
/// moment a hover circle is drawn around the glyph.
@MainActor
final class SidebarCenteredGlyphButtonCell: NSButtonCell {
    override func imageRect(forBounds rect: NSRect) -> NSRect {
        guard let image else { return super.imageRect(forBounds: rect) }
        let size = image.size
        return NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// Borderless glyph button used for the header chevron and plus controls.
@MainActor
final class SidebarHeaderGlyphButton: NSButton {
    override class var cellClass: AnyClass? {
        get { SidebarCenteredGlyphButtonCell.self }
        set {}
    }

    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    /// Opt-in pointer feedback: a soft circle behind the glyph and the glyph
    /// lifted to the full label colour while the pointer is on it.
    var highlightsOnHover = false {
        didSet { if !highlightsOnHover { setHovering(false) } }
    }

    /// The Aside-style hover instead (group header plus, row close): a
    /// circle on the bounds in this colour, 15% on hover and 22% pressed,
    /// with the glyph lifted to 65% of it. Owners pass the foreground of the
    /// surface it sits on, so the circle reads on an active row too.
    var hoverFillColor: NSColor? {
        didSet { if isHovering { applyHoverAppearance() } }
    }

    private var hasHoverFeedback: Bool { highlightsOnHover || hoverFillColor != nil }

    var glyphImage: NSImage? {
        didSet { image = glyphImage }
    }

    /// The tint the owner asked for; hover lifts the glyph away from it and
    /// must come back to exactly this, not to whatever it lifted to.
    private var restingTintColor: NSColor?
    private var isApplyingHoverTint = false
    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    override var contentTintColor: NSColor? {
        didSet {
            guard !isApplyingHoverTint else { return }
            restingTintColor = contentTintColor
            if isHovering { applyHoverAppearance() }
        }
    }

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        target = self
        action = #selector(didClick)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func didClick() {
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard hasHoverFeedback, isEnabled else { return }
        setHovering(true)
    }

    override var isHighlighted: Bool {
        didSet { if hoverFillColor != nil, isHighlighted != oldValue { applyHoverAppearance() } }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovering(false)
    }

    override func layout() {
        super.layout()
        if hasHoverFeedback {
            layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        }
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        applyHoverAppearance()
    }

    private func applyHoverAppearance() {
        wantsLayer = true
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        if let hoverFillColor {
            let alpha: CGFloat = isHovering ? (isHighlighted ? 0.22 : 0.15) : 0
            layer?.backgroundColor = hoverFillColor.withAlphaComponent(alpha).cgColor
            isApplyingHoverTint = true
            contentTintColor = isHovering ? hoverFillColor.withAlphaComponent(0.65) : restingTintColor
            isApplyingHoverTint = false
            return
        }
        // Dynamic colours resolve against the drawing appearance, so the
        // circle and glyph pick up the sidebar's own light/dark scheme.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isHovering
                ? NSColor.labelColor.withAlphaComponent(0.14).cgColor
                : NSColor.clear.cgColor
        }
        isApplyingHoverTint = true
        contentTintColor = isHovering ? .labelColor : restingTintColor
        isApplyingHoverTint = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    /// Starting state for hover-revealed buttons, and the reset on cell
    /// reuse. NSButton is born visible, so without this every fresh or
    /// recycled cell painted an X on its first unhovered configure, which
    /// flashed the close buttons on all rows at once after a workspace close.
    func concealImmediately() {
        setRevealed(false)
    }

    /// Hover reveal lands in the same frame as the hover change. The row
    /// swaps its trailing badge or spinner for this button synchronously, so
    /// a fade here left the slot blank on hover-in and doubled up on
    /// hover-out.
    func setRevealed(_ revealed: Bool) {
        isEnabled = revealed
        alphaValue = revealed ? 1 : 0
        isHidden = !revealed
        // Hover follows the pointer, not the last enter/exit pair: a click
        // that reflows rows, a drag, or a row scrolling under a still
        // pointer can skip the exit, and every reveal or conceal settles it.
        setHovering(revealed && hasHoverFeedback && pointerIsInside)
    }

    private var pointerIsInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}
