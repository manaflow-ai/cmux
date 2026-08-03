import AppKit
import CmuxSimulator

@MainActor
final class SimulatorAccessibilityOverlay: NSView {
    weak var coordinator: SimulatorPaneCoordinator?
    private var snapshot: SimulatorAccessibilitySnapshot?
    private var rows: [SimulatorAccessibilityPresentationRow] = []
    private var selectedNodeID: String?
    private var highlightedNodeID: String?
    private var chrome: SimulatorDeviceChromeProfile?
    private var frames: [SimulatorAccessibilityOverlayFrame] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(
        snapshot: SimulatorAccessibilitySnapshot?,
        rows: [SimulatorAccessibilityPresentationRow],
        selectedNodeID: String?,
        highlightedNodeID: String?,
        chrome: SimulatorDeviceChromeProfile?,
        isEnabled: Bool
    ) {
        self.snapshot = isEnabled ? snapshot : nil
        self.rows = rows
        self.selectedNodeID = selectedNodeID
        self.highlightedNodeID = highlightedNodeID
        self.chrome = chrome
        rebuildFrames()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        rebuildFrames()
    }

    override func draw(_ dirtyRect: NSRect) {
        for item in frames where item.rect.intersects(dirtyRect) {
            NSColor.systemBlue.withAlphaComponent(0.08).setFill()
            item.rect.fill()
            (selectedNodeID == item.node.id || highlightedNodeID == item.node.id
                ? NSColor.systemRed : NSColor.systemBlue).setStroke()
            NSBezierPath(rect: item.rect).stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let item = frames.last(where: { $0.rect.contains(point) }) else {
            return super.mouseDown(with: event)
        }
        coordinator?.selectAccessibilityOverlayNode(item.node)
    }

    private func rebuildFrames() {
        guard let snapshot, bounds.width > 0, bounds.height > 0 else {
            frames = []
            return
        }
        let appKitScreen = chrome?.screenRect(in: bounds, orientation: snapshot.display.orientation) ?? bounds
        let topLeftScreen = CGRect(
            x: appKitScreen.minX,
            y: bounds.height - appKitScreen.maxY,
            width: appKitScreen.width,
            height: appKitScreen.height
        )
        frames = simulatorAccessibilityOverlayFrames(rows: rows, screenRect: topLeftScreen)
    }
}
