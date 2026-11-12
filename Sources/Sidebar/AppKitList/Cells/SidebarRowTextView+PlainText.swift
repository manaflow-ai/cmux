import AppKit

extension SidebarRowTextView {
    /// Shows plain (non-link) text with an optional tooltip. Always resets
    /// the tooltip so a reused cell never keeps a previous entry's help.
    func configurePlainText(_ text: String, font: NSFont, color: NSColor, toolTip: String?) {
        stringValue = text
        self.font = font
        textColor = color
        self.toolTip = toolTip
    }
}
