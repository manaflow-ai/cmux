public import AppKit

/// Resolves a connected ``NSScreen`` from a free-form display query, backing the
/// `window.display` control command and the `cmux window display` CLI.
///
/// Faithful lift of `AppDelegate.screenMatching(_:)` from the AppDelegate god
/// file. The resolution order is unchanged: a trimmed, non-empty query matches a
/// screen by case-insensitive exact ``NSScreen/localizedName``, then by
/// case-insensitive substring, then by a zero-based index into
/// `NSScreen.screens`; an empty query or no match returns `nil` so callers can
/// report the available names.
///
/// A stateless value: it reads only the live `NSScreen.screens` handed to each
/// call, so it is a `Sendable` struct rather than an actor. The method is
/// `@MainActor` because it reads main-actor `NSScreen` properties. Constructed
/// (not a static namespace), mirroring ``NewWindowCascadePlanner``.
public struct DisplayMatcher: Sendable {
    /// Creates a display matcher.
    public init() {}

    /// Resolves the display matching `query`.
    ///
    /// Trims `query`; an empty query returns `nil`. Otherwise tries a
    /// case-insensitive exact name match, then a case-insensitive substring
    /// match, then a zero-based index into `NSScreen.screens`. Returns `nil` when
    /// nothing matches.
    ///
    /// - Parameter query: The user-supplied display name fragment or index string.
    /// - Returns: The matched screen, or `nil` when the query is empty or matches
    ///   no attached screen.
    @MainActor
    public func screen(matching query: String) -> NSScreen? {
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
