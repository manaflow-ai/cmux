import AppKit
import CmuxTerminal
import CmuxTerminalSharing
import CmuxTerminalSizing
import GhosttyKit
import SwiftUI

/// Draws a shared terminal's grid bounds over a pane (local and Cloud alike):
/// a 1.5 pt owner-colored border, a hatch outside the grid, a corner chip that
/// opens the size panel, an amber crop fade with a `+N cols` pill when the grid
/// is larger than the pane, and on each change a border flash plus a size HUD.
/// A `disconnected-by` detach of this Mac shows a card with Reattach.
///
/// Only the chip and the card take mouse events; everything else passes
/// through to the terminal. HUD and flash durations run on the injected clock.
@MainActor
final class TerminalSizeBoundsOverlayView: NSView {
    private static let hudDuration: Duration = .milliseconds(1400)
    private static let flashDuration: Duration = .milliseconds(700)
    private static let amber = NSColor(red: 0.914, green: 0.706, blue: 0.298, alpha: 1)

    private(set) var snapshot: TerminalSharingSnapshot?
    weak var terminalSurface: TerminalSurface?
    /// Opens the size panel anchored at a rect in this view.
    var onShowSizePanel: ((NSRect) -> Void)?
    /// Reattaches this Mac (`true` = as a viewer).
    var onReattach: ((Bool) -> Void)?

    private let clock: any Clock<Duration>
    private var hudTask: Task<Void, Never>?
    private var hudText: (size: String, owner: String)?
    private var isFlashing = false
    private var lastChangeKey: String?
    private var chipRect: NSRect = .zero
    private var detachedCardHost: NSHostingView<TerminalSharingDetachedCard>?

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// Whether a snapshot is shown; the legacy phone border hides while it is.
    var isPresentingSharing: Bool { snapshot?.isShared == true }

    func update(snapshot: TerminalSharingSnapshot?) {
        let previous = self.snapshot
        self.snapshot = snapshot
        updateDetachedCard()
        noteChange(previous: previous)
        isHidden = !(snapshot?.isShared ?? false)
        needsDisplay = true
    }

    /// Re-reads the surface geometry (pane resized or font changed).
    func refreshGeometry() {
        guard !isHidden else { return }
        needsDisplay = true
    }

    // MARK: Change feedback

    private func noteChange(previous: TerminalSharingSnapshot?) {
        guard let snapshot, snapshot.isShared else {
            lastChangeKey = nil
            return
        }
        let key = "\(snapshot.state.cols)x\(snapshot.state.rows)|\(snapshot.state.owners.joined(separator: ","))"
        defer { lastChangeKey = key }
        guard let lastChangeKey, lastChangeKey != key, let previous else { return }
        // Resizing your own window while you own the grid is not news; an
        // ownership change or someone else's resize is.
        let ownersChanged = previous.state.owners != snapshot.state.owners
        let selfOwns = snapshot.selfParticipantID.map { snapshot.state.owners == [$0] } ?? false
        guard ownersChanged || !selfOwns else { return }
        let display = TerminalSharingDisplay(snapshot: snapshot)
        hudText = (TerminalSharingDisplay.gridLabel(snapshot.state.size), display.ownerLabel)
        isFlashing = true
        hudTask?.cancel()
        let clock = clock
        hudTask = Task { @MainActor [weak self] in
            do { try await clock.sleep(for: Self.flashDuration) } catch { return }
            self?.isFlashing = false
            self?.needsDisplay = true
            do { try await clock.sleep(for: Self.hudDuration - Self.flashDuration) } catch { return }
            self?.hudText = nil
            self?.needsDisplay = true
        }
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
    }

    // MARK: Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        if let host = detachedCardHost, host.frame.contains(local) {
            return host.hitTest(convert(local, to: host.superview)) ?? host
        }
        return chipRect.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard chipRect.contains(local) else {
            super.mouseDown(with: event)
            return
        }
        onShowSizePanel?(chipRect)
    }

    override func resetCursorRects() {
        if !chipRect.isEmpty { addCursorRect(chipRect, cursor: .pointingHand) }
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
        chipRect = .zero
        guard let snapshot, snapshot.isShared, snapshot.detachment == nil,
              let geometry = currentGeometry(for: snapshot) else {
            window?.invalidateCursorRects(for: self)
            return
        }
        let display = TerminalSharingDisplay(snapshot: snapshot)
        let ownerColor = display.ownerNSColor
        if geometry.showsBounds {
            drawHatch(outside: geometry.gridRect)
            let border = NSBezierPath(rect: geometry.gridRect.insetBy(dx: 0.75, dy: 0.75))
            border.lineWidth = 1.5
            ownerColor.setStroke()
            border.stroke()
            if isFlashing {
                let glow = NSBezierPath(rect: geometry.gridRect.insetBy(dx: -1.5, dy: -1.5))
                glow.lineWidth = 4
                ownerColor.withAlphaComponent(0.45).setStroke()
                glow.stroke()
            }
        }
        if geometry.hiddenColumns > 0 { drawCrop(edge: .maxX, in: geometry.gridRect, hidden: geometry.hiddenColumns) }
        if geometry.hiddenRows > 0 { drawCrop(edge: .maxY, in: geometry.gridRect, hidden: geometry.hiddenRows) }
        if geometry.needsDecoration {
            drawChip(display: display, ownerColor: ownerColor, gridRect: geometry.gridRect)
        }
        if let hudText { drawHUD(size: hudText.size, owner: hudText.owner) }
        window?.invalidateCursorRects(for: self)
    }

    private func drawHatch(outside gridRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: gridRect).reversed)
        outside.addClip()
        let hatch = NSBezierPath()
        let spacing: CGFloat = 7
        var x = -bounds.height
        while x < bounds.width {
            hatch.move(to: NSPoint(x: x, y: bounds.height))
            hatch.line(to: NSPoint(x: x + bounds.height, y: 0))
            x += spacing
        }
        hatch.lineWidth = 1
        NSColor.secondaryLabelColor.withAlphaComponent(0.14).setStroke()
        hatch.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCrop(edge: NSRectEdge, in gridRect: NSRect, hidden: Int) {
        let depth: CGFloat = edge == .maxX ? 36 : 28
        let fadeRect = edge == .maxX
            ? NSRect(x: gridRect.maxX - depth, y: gridRect.minY, width: depth, height: gridRect.height)
            : NSRect(x: gridRect.minX, y: gridRect.maxY - depth, width: gridRect.width, height: depth)
        let gradient = NSGradient(starting: Self.amber.withAlphaComponent(0), ending: Self.amber.withAlphaComponent(0.28))
        gradient?.draw(in: fadeRect, angle: edge == .maxX ? 0 : 90)
        // Numbers and arrows only, so the pill needs no plural catalog entry.
        let text = edge == .maxX ? "+\(hidden) →" : "+\(hidden) ↓"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(red: 0.953, green: 0.804, blue: 0.494, alpha: 1),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let pill = edge == .maxX
            ? NSRect(x: gridRect.maxX - size.width - 22, y: gridRect.midY - 10, width: size.width + 16, height: 20)
            : NSRect(x: gridRect.midX - size.width / 2 - 8, y: gridRect.maxY - 26, width: size.width + 16, height: 20)
        let path = NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10)
        NSColor(red: 0.227, green: 0.18, blue: 0.078, alpha: 0.95).setFill()
        path.fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + (20 - size.height) / 2), withAttributes: attributes)
    }

    private func drawChip(display: TerminalSharingDisplay, ownerColor: NSColor, gridRect: NSRect) {
        let text = "\(TerminalSharingDisplay.gridLabel(display.state.size)) · \(display.ownerLabel)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let dot: CGFloat = 12
        let width = min(textSize.width + dot + 18, max(60, bounds.width - 12))
        let height: CGFloat = 20
        // Outside the grid's bottom-right corner when there is room, else inside.
        var origin = NSPoint(x: gridRect.maxX - width, y: gridRect.maxY + 6)
        if origin.y + height > bounds.height - 4 { origin.y = gridRect.maxY - height - 6 }
        origin.x = max(6, min(origin.x, bounds.width - width - 6))
        let rect = NSRect(origin: origin, size: NSSize(width: width, height: height))
        let path = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        path.fill()
        ownerColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let dotRect = NSRect(x: rect.minX + 4, y: rect.midY - dot / 2, width: dot, height: dot)
        ownerColor.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        let textRect = NSRect(x: dotRect.maxX + 6, y: rect.midY - textSize.height / 2, width: rect.maxX - dotRect.maxX - 12, height: textSize.height)
        (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)
        chipRect = rect
    }

    private func drawHUD(size: String, owner: String) {
        let sizeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let ownerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(white: 0.7, alpha: 1),
        ]
        let sizeText = size as NSString
        let ownerText = owner as NSString
        let sizeSize = sizeText.size(withAttributes: sizeAttributes)
        let ownerSize = ownerText.size(withAttributes: ownerAttributes)
        let width = sizeSize.width + ownerSize.width + 38
        let height = max(sizeSize.height, ownerSize.height) + 16
        let rect = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor(red: 0.078, green: 0.102, blue: 0.141, alpha: 0.92).setFill()
        path.fill()
        sizeText.draw(at: NSPoint(x: rect.minX + 14, y: rect.midY - sizeSize.height / 2), withAttributes: sizeAttributes)
        ownerText.draw(
            at: NSPoint(x: rect.minX + 24 + sizeSize.width, y: rect.midY - ownerSize.height / 2),
            withAttributes: ownerAttributes
        )
    }
}
