import Foundation

/// Repository for the trusted resume-source allowlist, persisted in
/// `UserDefaults` under the catalog's `terminal.trustedResumeSources` key.
///
/// The value is stored as a newline-joined string (the same encoding used by
/// the browser allowlists) so it round-trips through the managed-`UserDefaults`
/// config bridge that mirrors the cmux JSON config file.
///
/// Isolation: a stateless `Sendable` struct, not an actor. Every reader is
/// synchronous code that cannot await (resume-approval and prompt decisions),
/// the struct holds no mutable state, and `UserDefaults` is documented
/// thread-safe, so there is nothing for an actor to protect.
public struct TrustedResumeSourcesStore: TrustedResumeSourcesReading {
    /// The `UserDefaults`-backed change notification name. Posted when the
    /// allowlist is written through this store and the effective value changes.
    public static let didChangeNotification =
        Notification.Name("cmux.trustedResumeSourcesSettingsDidChange")

    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let keys = TerminalCatalogSection()

    /// Creates a store reading and writing the given defaults suite.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to read from and write to.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var trustedSources: [String] {
        Self.normalize(splitStoredValue(keys.trustedResumeSources.value(in: defaults)))
    }

    /// Replaces the stored allowlist, posting ``didChangeNotification`` when the
    /// effective (normalized) value changes.
    ///
    /// - Parameters:
    ///   - sources: The new source entries. Empty and whitespace-only entries
    ///     are dropped.
    ///   - notificationCenter: The center used to post the change notification.
    public func setTrustedSources(
        _ sources: [String],
        notificationCenter: NotificationCenter = .default
    ) {
        let previous = trustedSources
        let cleaned = sources
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        keys.trustedResumeSources.set(cleaned.joined(separator: "\n"), in: defaults)
        if previous != trustedSources {
            notificationCenter.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Clears the stored allowlist, posting ``didChangeNotification`` when the
    /// effective value changes.
    ///
    /// - Parameter notificationCenter: The center used to post the change
    ///   notification.
    /// - Returns: `true` when the effective value changed.
    @discardableResult
    public func reset(notificationCenter: NotificationCenter = .default) -> Bool {
        let previous = trustedSources
        keys.trustedResumeSources.removeValue(in: defaults)
        let didChange = previous != trustedSources
        if didChange {
            notificationCenter.post(name: Self.didChangeNotification, object: nil)
        }
        return didChange
    }

    /// Splits the newline-joined stored representation into raw entries.
    ///
    /// - Parameter stored: The newline-joined value read from defaults.
    /// - Returns: The raw, un-normalized entries.
    private func splitStoredValue(_ stored: String) -> [String] {
        guard !stored.isEmpty else { return [] }
        return stored.components(separatedBy: .newlines)
    }
}
