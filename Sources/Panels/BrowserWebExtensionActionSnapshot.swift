import AppKit

@available(macOS 15.4, *)
struct BrowserWebExtensionActionSnapshot: Identifiable {
    let id: String
    let displayName: String
    let icon: NSImage?

    var accessibilityIdentifier: String {
        let safeID = id.map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        .reduce(into: "") { $0.append($1) }
        return "BrowserWebExtensionActionButton-\(safeID)"
    }
}
