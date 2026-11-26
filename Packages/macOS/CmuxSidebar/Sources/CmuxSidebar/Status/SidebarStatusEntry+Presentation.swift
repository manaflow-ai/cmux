public import Foundation

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

    /// Tooltip for a single rendered row, shared by the AppKit and SwiftUI
    /// sidebars: the link target (if any), then ``sidebarHelpText`` when the
    /// entry carries ``helpText``. `nil` when there is nothing to show.
    /// - Parameter linkURL: The URL the row opens, if it is a link.
    public func sidebarToolTip(linkURL: URL?) -> String? {
        var parts: [String] = []
        if let linkURL { parts.append(linkURL.absoluteString) }
        if let helpText, !helpText.isEmpty { parts.append(sidebarHelpText) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
