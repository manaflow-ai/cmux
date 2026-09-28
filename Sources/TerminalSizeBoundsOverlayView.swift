import AppKit
import CmuxTerminal
import CmuxTerminalSharing
import CmuxTerminalSizing
import GhosttyKit
import QuartzCore
import SwiftUI

/// Draws a shared terminal's grid bounds over a pane (local and Cloud alike)
/// when this view's grid differs: a 1 pt owner-colored border, a faint hatch
/// outside the grid, a 16 pt fade on a cut edge, and one small chip
/// (`118×38 · Lawrence's Mac`) that opens the size panel at the tab. A
/// `disconnected-by` detach of this Mac shows a card with Reattach.
///
/// Only the chip and the card take mouse events; everything else passes
/// through to the terminal. A size change animates the border to the new grid.
@MainActor
final class TerminalSizeBoundsOverlayView: NSView {
    private static let amber = NSColor(red: 0.914, green: 0.706, blue: 0.298, alpha: 1)
    private static let borderAlpha: CGFloat = 0.7
    private static let cropFadeDepth: CGFloat = 16

    private(set) var snapshot: TerminalSharingSnapshot?
    weak var terminalSurface: TerminalSurface?
    /// Opens the size panel (anchored at the terminal's tab).
    var onShowSizePanel: (() -> Void)?
    /// Reattaches this Mac (`true` = as a viewer).
    var onReattach: ((Bool) -> Void)?

    private let borderLayer = CAShapeLayer()
    private let chip = TerminalSizeBoundsChipView()
    private var lastGridKey: String?
    private var animateNextBorderChange = false
    private var detachedCardHost: NSHostingView<TerminalSharingDetachedCard>?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        borderLayer.actions = ["path": NSNull(), "strokeColor": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(borderLayer)
        chip.isHidden = true
        chip.onPress = { [weak self] in self?.onShowSizePanel?() }
        addSubview(chip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// Whether a snapshot is shown; the legacy phone border hides while it is.
    var isPresentingSharing: Bool { snapshot?.showsSizingChrome == true }

    func update(snapshot: TerminalSharingSnapshot?) {
        self.snapshot = snapshot
        updateDetachedCard()
        let key = snapshot.map { "\($0.state.cols)x\($0.state.rows)" }
        if let key, let lastGridKey, key != lastGridKey { animateNextBorderChange = true }
        lastGridKey = key
        isHidden = !(snapshot?.showsSizingChrome ?? false)
        needsDisplay = true
        needsLayout = true
    }

    /// Re-reads the surface geometry (pane resized or font changed).
    func refreshGeometry() {
        guard !isHidden else { return }
        needsDisplay = true
        needsLayout = true
    }

    // MARK: Detached card

    private func updateDetachedCard() {
        guard let detachment = snapshot?.detachment else {
            detachedCardHost?.removeFromSuperview()
            detachedCardHost = nil
            return
        }
        let card = TerminalSharingDetachedCard(detachment: detachment) { [weak self] asViewer in
            self?.onReattach?(asViewer)
        }
        if let detachedCardHost {
            detachedCardHost.rootView = card
        } else {
            let host = NSHostingView(rootView: card)
            addSubview(host)
            detachedCardHost = host
        }
        needsLayout = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        if let host = detachedCardHost {
            let size = host.fittingSize
            host.frame = NSRect(
                x: max(0, (bounds.width - size.width) / 2),
                y: max(0, (bounds.height - size.height) / 2),
                width: min(size.width, bounds.width),
                height: min(size.height, bounds.height)
            )
        }
        layoutBoundsChrome()
    }

    private func layoutBoundsChrome() {
        borderLayer.frame = layer?.bounds ?? bounds
        guard let snapshot, snapshot.showsSizingChrome, snapshot.detachment == nil,
              let geometry = currentGeometry(for: snapshot), geometry.needsDecoration else {
            borderLayer.isHidden = true
            chip.isHidden = true
            return
        }
        let display = TerminalSharingDisplay(snapshot: snapshot)
        updateBorder(geometry: geometry, color: display.ownerNSColor)
        chip.text = display.presentation.chipText(hiddenColumns: geometry.hiddenColumns)
        chip.frame = chipFrame(size: chip.fittingSize, gridRect: geometry.gridRect)
        chip.isHidden = false
    }

    private func updateBorder(geometry: TerminalSizeBoundsGeometry, color: NSColor) {
        guard geometry.showsBounds else {
            borderLayer.isHidden = true
            return
        }
        let rect = layerRect(geometry.gridRect.insetBy(dx: 0.5, dy: 0.5))
        let path = CGPath(rect: rect, transform: nil)
        let previous = borderLayer.presentation()?.path ?? borderLayer.path
        let wasHidden = borderLayer.isHidden
        borderLayer.isHidden = false
        borderLayer.strokeColor = color.withAlphaComponent(Self.borderAlpha).cgColor
        borderLayer.path = path
        if animateNextBorderChange, !wasHidden, let previous, previous != path {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = previous
            animation.toValue = path
            animation.duration = 0.2
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            borderLayer.add(animation, forKey: "path")
        }
        animateNextBorderChange = false
    }

    /// Converts a rect in this flipped view to the border layer's space.
    private func layerRect(_ rect: NSRect) -> CGRect {
        if borderLayer.contentsAreFlipped() { return rect }
        return CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Outside the grid's bottom-right corner when there is room, else inside it.
    private func chipFrame(size: NSSize, gridRect: NSRect) -> NSRect {
        let margin: CGFloat = 4
        let width = min(size.width, max(40, bounds.width - 2 * margin))
        var origin = NSPoint(x: gridRect.maxX - width, y: gridRect.maxY + margin)
        if origin.y + size.height > bounds.height - margin {
            origin.y = min(gridRect.maxY, bounds.height) - size.height - margin
        }
        origin.x = max(margin, min(origin.x, bounds.width - width - margin))
        return NSRect(origin: origin, size: NSSize(width: width, height: size.height))
    }

    // MARK: Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        if let host = detachedCardHost, host.frame.contains(local) {
            return host.hitTest(convert(local, to: host.superview)) ?? host
        }
        if !chip.isHidden, chip.frame.contains(local) { return chip }
        return nil
    }

    // MARK: Drawing

    private func currentGeometry(for snapshot: TerminalSharingSnapshot) -> TerminalSizeBoundsGeometry? {
        guard let surface = terminalSurface?.liveSurfaceForGhosttyAccess(reason: "terminalSizeBoundsOverlay") else {
            return nil
        }
        let size = ghostty_surface_size(surface)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return TerminalSizeBoundsGeometry(
            paneSize: bounds.size,
            surfacePixelSize: CGSize(width: CGFloat(size.width_px), height: CGFloat(size.height_px)),
            cellPixelSize: CGSize(width: CGFloat(size.cell_width_px), height: CGFloat(size.cell_height_px)),
            scale: scale,
            grid: snapshot.state.size
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let snapshot, snapshot.showsSizingChrome, snapshot.detachment == nil,
              let geometry = currentGeometry(for: snapshot) else { return }
        if geometry.showsBounds { drawHatch(outside: geometry.gridRect) }
        if geometry.hiddenColumns > 0 { drawCropFade(edge: .maxX, in: geometry.gridRect) }
        if geometry.hiddenRows > 0 { drawCropFade(edge: .maxY, in: geometry.gridRect) }
    }

    private func drawHatch(outside gridRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: gridRect).reversed)
        outside.addClip()
        let hatch = NSBezierPath()
        let spacing: CGFloat = 8
        var x = -bounds.height
        while x < bounds.width {
            hatch.move(to: NSPoint(x: x, y: bounds.height))
            hatch.line(to: NSPoint(x: x + bounds.height, y: 0))
            x += spacing
        }
        hatch.lineWidth = 0.5
        NSColor.secondaryLabelColor.withAlphaComponent(0.07).setStroke()
        hatch.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCropFade(edge: NSRectEdge, in gridRect: NSRect) {
        let depth = Self.cropFadeDepth
        let fadeRect = edge == .maxX
            ? NSRect(x: gridRect.maxX - depth, y: gridRect.minY, width: depth, height: gridRect.height)
            : NSRect(x: gridRect.minX, y: gridRect.maxY - depth, width: gridRect.width, height: depth)
        let gradient = NSGradient(starting: Self.amber.withAlphaComponent(0), ending: Self.amber.withAlphaComponent(0.22))
        // This view is flipped, so a 90° gradient runs top to bottom.
        gradient?.draw(in: fadeRect, angle: edge == .maxX ? 0 : 90)
    }
}

/// The pane chip `118×38 · Lawrence's Mac`: an accessibility button that
/// opens the size panel at the terminal's tab.
@MainActor
final class TerminalSizeBoundsChipView: NSView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 3

    var onPress: (() -> Void)?
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    override var isFlipped: Bool { true }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor]
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    override var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: attributes)
        return NSSize(
            width: ceil(size.width) + 2 * Self.horizontalPadding,
            height: ceil(size.height) + 2 * Self.verticalPadding
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NSColor.windowBackgroundColor.withAlphaComponent(0.72).setFill()
        path.fill()
        let textRect = bounds.insetBy(dx: Self.horizontalPadding, dy: Self.verticalPadding)
        (text as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes,
            context: nil
        )
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { text }
    override func accessibilityIdentifier() -> String { "terminalSizeChip" }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
