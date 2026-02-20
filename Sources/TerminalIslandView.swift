import AppKit
import ObjectiveC

func islandLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    let path = "/tmp/cmux-island-debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

/// A shallow container view that hosts visible terminal surfaces as direct children
/// of the window's content view, bypassing the deep SwiftUI view hierarchy.
///
/// Without this, terminal surfaces sit ~15 layers deep in the SwiftUI tree. CA::Transaction::commit
/// traverses all layers every frame, queuing key events behind the commit. By lifting terminals
/// to a depth of ~4 (island → scrollView → clipView → metalLayer), we eliminate the traversal
/// cost and reduce typing latency.
///
/// The island is installed as a sibling of the NSHostingView (or inside NSGlassEffectView on Tahoe),
/// positioned above the SwiftUI tree via z-ordering. Hit testing passes through empty regions
/// so clicks on tab bars, sidebar, and dividers reach SwiftUI.
@MainActor
final class TerminalIslandView: NSView {
    private static var islandKey: UInt8 = 0
    /// The contentView whose frame we mirror (when installed in themeFrame).
    private weak var trackedContentView: NSView?

    /// Per-terminal slot tracking.
    private struct TerminalSlot {
        let hostedView: GhosttySurfaceScrollView
        var frame: NSRect
        var dimmingLayer: CALayer?
        var notificationBorderLayer: CALayer?
    }

    private var slots: [UUID: TerminalSlot] = [:]

    // MARK: - Installation

    /// Install a TerminalIslandView on the given window. Idempotent.
    @discardableResult
    static func install(on window: NSWindow) -> TerminalIslandView {
        if let existing = island(for: window) {
            return existing
        }

        let island = TerminalIslandView(frame: .zero)
        island.wantsLayer = true
        island.autoresizingMask = [.width, .height]

        // Add the island to contentView's superview (the window's theme frame),
        // positioned above the contentView. This keeps the island above SwiftUI's
        // entire hosting view, which continuously manages its own subview hierarchy
        // and would bury a child island behind its layers.
        if let contentView = window.contentView, let themeFrame = contentView.superview {
            // Match contentView's frame exactly — NOT themeFrame.bounds, which can be
            // much larger (glass effects, display scaling). This ensures coordinate
            // conversion from HostContainerView (inside contentView) to island produces
            // correct positions.
            island.trackedContentView = contentView
            island.frame = contentView.frame
            island.autoresizingMask = []  // We sync frame via notification, not autoresize
            themeFrame.addSubview(island, positioned: .above, relativeTo: contentView)

            // Track contentView frame changes (resize, fullscreen, etc.)
            contentView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                island,
                selector: #selector(trackedContentViewFrameChanged),
                name: NSView.frameDidChangeNotification,
                object: contentView
            )

            islandLog("install: themeFrame=\(type(of: themeFrame)) cv.frame=\(contentView.frame) island.frame=\(island.frame) island.window=\(island.window != nil)")
        } else if let contentView = window.contentView {
            // Fallback: add inside contentView if no superview available.
            island.frame = contentView.bounds
            contentView.addSubview(island, positioned: .above, relativeTo: nil)
            islandLog("install fallback: inside contentView, bounds=\(contentView.bounds)")
        } else {
            islandLog("install: contentView is nil!")
        }

        objc_setAssociatedObject(window, &islandKey, island, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return island
    }

    /// Retrieve the island for a given window, if installed.
    static func island(for window: NSWindow) -> TerminalIslandView? {
        objc_getAssociatedObject(window, &islandKey) as? TerminalIslandView
    }

    // MARK: - Frame tracking

    @objc private func trackedContentViewFrameChanged(_ notification: Notification) {
        guard let contentView = trackedContentView else { return }
        self.frame = contentView.frame
    }

    override func removeFromSuperview() {
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: trackedContentView)
        super.removeFromSuperview()
    }

    // MARK: - NSView overrides

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only intercept hits that land on an actual terminal surface.
        // Everything else (tab bar, sidebar, dividers) passes through to SwiftUI below.
        for slot in slots.values {
            if slot.frame.contains(point) {
                // Convert to the hosted view's coordinate space and let it handle hit testing.
                let localPoint = NSPoint(x: point.x - slot.frame.origin.x,
                                         y: point.y - slot.frame.origin.y)
                if let hit = slot.hostedView.hitTest(localPoint) {
                    return hit
                }
            }
        }
        return nil
    }

    // MARK: - Terminal slot management

    /// Add or re-add a terminal surface to the island at the given frame.
    func addTerminal(panelId: UUID, hostedView: GhosttySurfaceScrollView, frame: NSRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // If already tracked and parented here, just update frame.
        if var existing = slots[panelId], existing.hostedView === hostedView {
            existing.frame = frame
            hostedView.frame = frame
            hostedView.needsLayout = true
            slots[panelId] = existing
            updateOverlayFrames(panelId: panelId, frame: frame)
            return
        }

        let prevSuperview = hostedView.superview
        let prevWindow = hostedView.window

        // Remove from any previous parent (could be a HostContainerView or another island).
        if hostedView.superview !== self {
            hostedView.removeFromSuperview()
            addSubview(hostedView)
        }

        hostedView.translatesAutoresizingMaskIntoConstraints = true
        hostedView.autoresizingMask = []
        hostedView.frame = frame
        // Force layout so subviews (scrollView, surfaceView, CAMetalLayer) resize to the
        // new frame immediately. Without this, the terminal can appear blank after reparenting.
        hostedView.needsLayout = true
        hostedView.layoutSubtreeIfNeeded()

        slots[panelId] = TerminalSlot(hostedView: hostedView, frame: frame)

        islandLog("addTerminal: panel=\(panelId) frame=\(frame) prevSuper=\(type(of: prevSuperview)) prevWin=\(prevWindow != nil) nowSuper=\(hostedView.superview === self) nowWin=\(hostedView.window != nil) islandFrame=\(self.frame) islandWin=\(self.window != nil) subviewCount=\(self.subviews.count)")
    }

    /// Remove a terminal surface from the island (e.g., when workspace goes invisible).
    func removeTerminal(panelId: UUID) {
        guard let slot = slots.removeValue(forKey: panelId) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        slot.hostedView.removeFromSuperview()
        slot.dimmingLayer?.removeFromSuperlayer()
        slot.notificationBorderLayer?.removeFromSuperlayer()
    }

    /// Update the frame of a terminal surface (called from HostContainerView frame changes).
    func updateFrame(panelId: UUID, frame: NSRect) {
        guard var slot = slots[panelId] else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        slot.frame = frame
        slot.hostedView.frame = frame
        slot.hostedView.needsLayout = true
        slots[panelId] = slot
        updateOverlayFrames(panelId: panelId, frame: frame)
    }

    /// Remove all terminals (e.g., window closing).
    func removeAllTerminals() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for slot in slots.values {
            slot.hostedView.removeFromSuperview()
            slot.dimmingLayer?.removeFromSuperlayer()
            slot.notificationBorderLayer?.removeFromSuperlayer()
        }
        slots.removeAll()
    }

    // MARK: - Overlay layers

    /// Set a dimming overlay on a terminal (for unfocused split panes).
    func setDimming(panelId: UUID, color: NSColor, opacity: CGFloat) {
        guard var slot = slots[panelId] else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if opacity <= 0 {
            slot.dimmingLayer?.removeFromSuperlayer()
            slot.dimmingLayer = nil
            slots[panelId] = slot
            return
        }

        let layer: CALayer
        if let existing = slot.dimmingLayer {
            layer = existing
        } else {
            layer = CALayer()
            layer.zPosition = 100
            self.layer?.addSublayer(layer)
            slot.dimmingLayer = layer
            slots[panelId] = slot
        }

        layer.frame = slot.frame
        layer.backgroundColor = color.withAlphaComponent(opacity).cgColor
    }

    /// Set a notification border around a terminal.
    func setNotificationBorder(panelId: UUID, visible: Bool, color: NSColor) {
        guard var slot = slots[panelId] else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if !visible {
            slot.notificationBorderLayer?.removeFromSuperlayer()
            slot.notificationBorderLayer = nil
            slots[panelId] = slot
            return
        }

        let layer: CALayer
        if let existing = slot.notificationBorderLayer {
            layer = existing
        } else {
            layer = CALayer()
            layer.zPosition = 101
            self.layer?.addSublayer(layer)
            slot.notificationBorderLayer = layer
            slots[panelId] = slot
        }

        // Inset by 2pt to match SwiftUI's .padding(2) on the border
        let insetFrame = slot.frame.insetBy(dx: 2, dy: 2)
        layer.frame = insetFrame
        layer.borderColor = color.cgColor
        layer.borderWidth = 2.5
        layer.cornerRadius = 0
        layer.shadowColor = color.withAlphaComponent(0.35).cgColor
        layer.shadowRadius = 3
        layer.shadowOpacity = 1
        layer.shadowOffset = .zero
        layer.backgroundColor = nil
    }

    // MARK: - Private helpers

    private func updateOverlayFrames(panelId: UUID, frame: NSRect) {
        if let slot = slots[panelId] {
            slot.dimmingLayer?.frame = frame
            if let borderLayer = slot.notificationBorderLayer {
                borderLayer.frame = frame.insetBy(dx: 2, dy: 2)
            }
        }
    }
}
