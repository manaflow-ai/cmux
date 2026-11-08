public import AppKit
import CmuxNextDesign

extension NSView {
    /// A pane content area's own fill, what shows where its content does not draw: `surface`, or under a terminal tab
    /// (`terminal`) the terminal's background as ``TerminalHostView`` paints it with no theme of its own. A split's new
    /// terminal has no surface in the key's frame (`AfterKeyFrameGate`) and its surface draws frames later: its pane
    /// shows the terminal's color from the key's frame, never the window's other color (Leo: "content never blank").
    /// `paints`: the window is opaque here (`WindowBackdrop.panesPaintBackground`); nil is clear, where the window
    /// root paints the one sheet.
    ///
    /// ```swift
    /// contentHost.layer?.backgroundColor = paneContentFill(paints: paints, surface: Palette.surfaceBackground, terminal: true)
    /// ```
    public func paneContentFill(paints: Bool, surface: NSColor, terminal: Bool) -> CGColor? {
        if terminal, let own = performWithTheme({ Palette.surfaceOverride(.terminal) }) { return own.cgColor }
        guard paints else { return nil }
        return (terminal ? GhosttyRuntime.shared.backgroundColor : surface).cgColor
    }
}
