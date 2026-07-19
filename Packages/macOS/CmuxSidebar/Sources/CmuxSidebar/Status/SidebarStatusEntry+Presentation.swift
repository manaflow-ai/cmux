import Foundation

public extension SidebarStatusEntry {
    /// Text shown for this entry by every built-in workspace sidebar renderer.
    var sidebarDisplayText: String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? key : trimmedValue
    }
}
