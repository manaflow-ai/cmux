extension MobileTerminalRenderGridFrame.Style {
    /// The terminal color source retained by a render-grid style.
    ///
    /// Keeping default and palette colors semantic lets a mirrored terminal
    /// respond to later theme changes instead of baking the producer's
    /// current resolved RGB value into every cell.
    public enum ColorSource: String, Codable, Equatable, Sendable {
        /// The terminal's current default foreground or background.
        case defaultColor = "default"
        /// An indexed terminal palette color.
        case palette
        /// A literal RGB color that must not change with the theme.
        case rgb
    }
}
