import AppKit

@available(macOS 15.4, *)
struct BrowserWebExtensionActionSnapshot: Identifiable {
    let id: String
    let displayName: String
    let icon: NSImage?
    let isEnabled: Bool
    let badgeText: String
    let hasUnreadBadgeText: Bool
    /// Whether the toolbar renders this extension's button (the extension
    /// stays loaded and its shortcuts keep working when hidden).
    let showsToolbarButton: Bool
    /// Settings-backed entries can persist the visibility toggle;
    /// environment-injected extensions cannot.
    let canToggleToolbarButton: Bool

    var accessibilityIdentifier: String {
        let safeID = id.map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        .reduce(into: "") { $0.append($1) }
        return "BrowserWebExtensionActionButton-\(safeID)"
    }
}
