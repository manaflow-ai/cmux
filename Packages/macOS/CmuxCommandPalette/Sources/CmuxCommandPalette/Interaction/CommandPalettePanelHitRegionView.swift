import AppKit

/// Passive AppKit marker backing ``CommandPalettePanelHitRegion``.
final class CommandPalettePanelHitRegionView: NSView {
    static let interfaceIdentifier = NSUserInterfaceItemIdentifier(
        "cmux.commandPalette.panelHitRegion"
    )

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { postGeometryChange() }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let changed = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        if changed { postGeometryChange() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        postGeometryChange()
    }

    private func postGeometryChange() {
        NotificationCenter.default.post(name: CommandPalettePanelHitRegion.geometryDidChangeNotification, object: self)
    }
}
