public import Foundation

/// Resolves browser-import destination selectors without touching app storage.
public struct BrowserImportDestinationResolver: Sendable {
    /// The result of resolving a destination selector.
    public enum Resolution: Equatable, Sendable {
        /// No destination selector was supplied.
        case none
        /// An existing profile was selected by its stable identifier.
        case matched(UUID)
        /// More than one profile matched the display name or slug.
        case ambiguous([BrowserProfileDefinition])
        /// No profile matched and creation was not requested.
        case notFound(String)
        /// The UUID-only selector was malformed or unknown.
        case invalidIdentifier(String)
        /// The caller requested creation after no existing profile matched.
        case create(String)
    }

    /// Creates a stateless destination resolver.
    public init() {}

    /// Resolves an optional UUID or name/slug selector against profiles.
    ///
    /// - Parameters:
    ///   - rawSelector: A display name or slug, when supplied.
    ///   - rawIdentifier: The UUID-only selector, when supplied.
    ///   - createIfMissing: Whether a missing name may create a profile.
    ///   - profiles: The current profile definitions.
    /// - Returns: A deterministic resolution result; no app state is mutated.
    public func resolve(
        rawSelector: String?,
        rawIdentifier: String?,
        createIfMissing: Bool,
        profiles: [BrowserProfileDefinition]
    ) -> Resolution {
        let identifier = rawIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let identifier, !identifier.isEmpty {
            guard let id = UUID(uuidString: identifier),
                  profiles.contains(where: { $0.id == id }) else {
                return .invalidIdentifier(identifier)
            }
            return .matched(id)
        }

        guard let rawSelector else { return .none }
        let selector = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else { return .notFound(selector) }
        if let id = UUID(uuidString: selector) {
            return profiles.contains(where: { $0.id == id })
                ? .matched(id)
                : .invalidIdentifier(selector)
        }
        let matches = profiles.filter {
            $0.displayName.localizedCaseInsensitiveCompare(selector) == .orderedSame
                || $0.slug.localizedCaseInsensitiveCompare(selector) == .orderedSame
        }
        if matches.count == 1 { return .matched(matches[0].id) }
        if matches.count > 1 { return .ambiguous(matches) }
        return createIfMissing ? .create(selector) : .notFound(selector)
    }
}
