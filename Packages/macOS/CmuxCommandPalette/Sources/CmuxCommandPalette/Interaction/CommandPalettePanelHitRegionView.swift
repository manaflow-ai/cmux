import AppKit

/// Passive AppKit marker backing ``CommandPalettePanelHitRegion``.
final class CommandPalettePanelHitRegionView: NSView {
    static let interfaceIdentifier = NSUserInterfaceItemIdentifier(
        "cmux.commandPalette.panelHitRegion"
    )

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
