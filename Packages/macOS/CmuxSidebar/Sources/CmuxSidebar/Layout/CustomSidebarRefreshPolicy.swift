public import Foundation

/// How often a custom sidebar's data context has to be rebuilt.
///
/// Only the `clock` data key changes with wall time; every other key changes
/// only when workspace state does. Rebuilding the context once a second for a
/// sidebar that never reads `clock` repeats the full per-workspace projection
/// and re-renders the sidebar for nothing (issue #46725), so the host ticks
/// only sidebars whose source names `clock` and rebuilds the rest when their
/// data changes.
public enum CustomSidebarRefreshPolicy: Sendable, Equatable {
    /// Rebuild every second, so `clock` stays live.
    case everySecond
    /// Rebuild when sidebar data changes.
    case onDataChange

    /// The interval between rebuilds for ``everySecond``.
    public static let clockInterval: TimeInterval = 1

    /// The interval of the safety rebuild for ``onDataChange``.
    ///
    /// A few inputs (agent `lastActivityAt`, agent children, a pure tab
    /// reorder) have no change signal. This rebuild picks them up. When
    /// nothing changed it builds an equal context, and every renderer skips
    /// an equal context, so the sidebar does not re-render.
    public static let fallbackInterval: TimeInterval = 5

    /// Chooses the policy for sidebar source text.
    ///
    /// The check is lexical and conservative: any `clock` identifier
    /// (`data.clock()` in `.js`, `clock.time` in `.swift`, a `clock` binding
    /// in `.json`) selects ``everySecond``. A false positive costs only the
    /// old once-a-second rebuild; a false negative would freeze a clock, so
    /// comments and strings that mention `clock` also count.
    public static func policy(forSource source: String) -> Self {
        sourceReadsClock(source) ? .everySecond : .onDataChange
    }

    /// Chooses the policy for every file a sidebar may load.
    ///
    /// A sidebar is resolved by name and its loaded file can switch between
    /// `.swift`, `.json` and `.js` across reloads, so the policy ticks when
    /// any candidate reads `clock`.
    public static func policy(forSources sources: [String]) -> Self {
        sources.contains(where: sourceReadsClock) ? .everySecond : .onDataChange
    }

    /// True when `source` contains `clock` as a whole identifier.
    public static func sourceReadsClock(_ source: String) -> Bool {
        var searchStart = source.startIndex
        while let match = source.range(of: "clock", range: searchStart..<source.endIndex) {
            let before = match.lowerBound == source.startIndex
                ? nil
                : source[source.index(before: match.lowerBound)]
            let after = match.upperBound == source.endIndex ? nil : source[match.upperBound]
            if !isIdentifierCharacter(before), !isIdentifierCharacter(after) {
                return true
            }
            searchStart = match.upperBound
        }
        return false
    }

    private static func isIdentifierCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character == "_" || character == "$" || character.isLetter || character.isNumber
    }
}
