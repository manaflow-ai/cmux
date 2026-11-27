import AppKit

extension Fixture {
    /// cmux: the composer's own text (file names in its attachment strip): the theme's text, not a
    /// chat's chosen received-bubble text (`HomePalette.composeText`).
    static var composeText: NSColor { theme?.active.composeText ?? incomingText }
}
