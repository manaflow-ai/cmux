public import AppKit
import CmuxNextDesign

/// A terminal tab a pane shows before its surface does (a split's stand-in, made after its key's frame,
/// `AfterKeyFrameGate`): the theme its terminal will draw with, nil for the Ghostty config's.
@MainActor
public struct AwaitedTerminal: Equatable {
    public let theme: GhosttyThemeConfig?

    public init(theme: GhosttyThemeConfig?) { self.theme = theme }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.theme === rhs.theme }
}

extension NSView {
    /// A pane content area's own fill, what shows where its content does not draw: `surface`, or while the pane waits
    /// for a terminal's surface (`awaiting`) the background that terminal's ``TerminalHostView`` will paint, so a split's
    /// new terminal shows the terminal's color from the key's frame, never the window's other color (Leo: "content
    /// never blank"). Once the host shows it paints that background itself, and the pane goes back to `surface` under it.
    /// `paints`: the window is opaque here (`WindowBackdrop.panesPaintBackground`); nil is clear, where the window
    /// root paints the one sheet.
    ///
    /// ```swift
    /// contentHost.layer?.backgroundColor = paneContentFill(paints: paints, surface: Palette.surfaceBackground, awaiting: awaitedTerminal)
    /// ```
    public func paneContentFill(paints: Bool, surface: NSColor, awaiting terminal: AwaitedTerminal?) -> CGColor? {
        guard let terminal else { return paints ? surface.cgColor : nil }
        if let own = performWithTheme({ Palette.surfaceOverride(.terminal) }) { return own.cgColor }
        guard paints else { return nil }
        guard let rgb = terminal.theme?.colors?.background else { return GhosttyRuntime.shared.backgroundColor.cgColor }
        return CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}
