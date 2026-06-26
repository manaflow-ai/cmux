public import AppKit

extension NSScreen {
    /// Resolve a screen from a display query, or `nil` when nothing matches so
    /// callers can report the available names.
    ///
    /// Faithful lift of `AppDelegate.screenMatching(_:)`. The query is trimmed of
    /// surrounding whitespace, then matched in this precedence: case-insensitive
    /// exact `localizedName`, then case-insensitive `localizedName` substring,
    /// then a zero-based index string into `NSScreen.screens`. An empty trimmed
    /// query never matches. Reads main-actor `NSScreen` state, so it is
    /// `@MainActor`.
    @MainActor
    public static func cmuxScreen(matching query: String) -> NSScreen? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let screens = NSScreen.screens
        if let exact = screens.first(where: {
            $0.localizedName.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exact
        }
        let lowered = trimmed.lowercased()
        if let partial = screens.first(where: { $0.localizedName.lowercased().contains(lowered) }) {
            return partial
        }
        if let index = Int(trimmed), index >= 0, index < screens.count {
            return screens[index]
        }
        return nil
    }
}
