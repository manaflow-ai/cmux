import Foundation

extension SidebarStatusEntry {
    /// Text shown for this entry by every built-in workspace sidebar renderer.
    public var sidebarDisplayText: String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? key : trimmedValue
    }

    /// Tooltip text: the display text, followed by ``helpText`` when set.
    public var sidebarHelpText: String {
        guard let helpText, !helpText.isEmpty else { return sidebarDisplayText }
        return sidebarDisplayText + "\n" + helpText
    }
}
