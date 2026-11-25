#if DEBUG
public import AppKit

/// The overlay a native tab-row tools capture drives. CmuxNextTabs' DebugNativeRowToolsFixtureView
/// conforms; CmuxNextAgentPane's DebugNativeRowToolsFixture shows it, so neither module imports the other.
@MainActor
public protocol DebugNativeRowToolsOverlay: NSView {
    /// Creates the overlay over `frame`.
    init(frame: NSRect)
    /// Shows `tools` in a row of `width` points.
    func configure(tools: [PaneTabRowTool], width: CGFloat)
    /// Opens the menu of the visible enabled tool `id`; false when there is none.
    func openMenu(_ id: String) -> Bool
    /// The capture rectangle in window coordinates, or nil when it extends outside the window.
    func snapshotBounds() -> (capture: NSRect, menuVisible: Bool)?
}
#endif
