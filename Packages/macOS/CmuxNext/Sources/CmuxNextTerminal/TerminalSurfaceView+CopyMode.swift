public import AppKit

// Copy mode's public entrypoints; ``TerminalCopyMode`` owns the session.

extension TerminalSurfaceView {
    public var isCopyModeActive: Bool { copyMode.isActive }

    /// Enters or leaves copy mode. False when the surface cannot enter it.
    @discardableResult
    public func toggleCopyMode() -> Bool { copyMode.toggle() }

    /// Leaves copy mode and clears its selection.
    public func exitCopyMode() { copyMode.exit() }
}
