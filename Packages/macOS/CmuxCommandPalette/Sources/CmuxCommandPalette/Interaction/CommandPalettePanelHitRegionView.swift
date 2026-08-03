public import AppKit

/// Passive native marker for command-palette outside-click routing.
public final class CommandPalettePanelHitRegionView: NSView {
    static let interfaceIdentifier = NSUserInterfaceItemIdentifier(
        "cmux.commandPalette.panelHitRegion"
    )

    /// Creates a marker whose frame defines the palette's interactive bounds.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.interfaceIdentifier
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
