import Foundation

extension SidebarStatusEntry {
    /// Text shown for this entry by every built-in workspace sidebar renderer.
    public var sidebarDisplayText: String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? key : trimmedValue
    }
}
