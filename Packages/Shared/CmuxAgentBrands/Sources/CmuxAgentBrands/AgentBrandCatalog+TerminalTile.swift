import CoreGraphics

/// A terminal agent's rounded square (Claude Code, Codex in a terminal tab), the one rule the Mac's tabs and
/// sidebar and the iPhone's avatars draw it by; a GUI agent chat keeps a bare mark (Mac) or a circle (iPhone).
public extension AgentBrandCatalog {
    /// The corner radius as a share of the square's side (close to an app icon's).
    static let terminalTileCornerShare: CGFloat = 0.3
    /// How much of the tint a mono tile shows under its mark.
    static let terminalTileAlpha: CGFloat = 0.2
    /// The mark's side as a share of a mono tile's.
    static let terminalTileMarkShare: CGFloat = 0.6
}
