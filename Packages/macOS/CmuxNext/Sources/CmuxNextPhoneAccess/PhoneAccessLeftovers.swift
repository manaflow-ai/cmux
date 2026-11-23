import Foundation

/// What the removed iroh phone listener (Settings > Accounts > Phone Access, #42780) left that
/// only cmux-next wrote, deleted once at launch (the App's `LaunchCleanup`), off the main thread.
///
/// That is one key in this app's own defaults domain: `cmux.phoneAccess.migrated.v1`, the
/// one-time flag of the removed `PhoneAccessMigration`. Deleting an absent key does nothing, so
/// every launch after the first is a single lookup.
///
/// Deliberately kept: the listener's v2 device identity, the Keychain services
/// `<bundle id>.cmux-iroh-v2.installation` (account `device-id`) and
/// `<bundle id>.cmux-iroh-v2.endpoint-keys`, and its files under
/// `Application Support/<bundle id>/cmux-iroh-v2/` (`state/*.sealed`, Debug `development-keys`).
/// Classic cmux writes the same names under the same bundle ids (cmux NIGHTLY ships from both
/// tracks as `com.cmuxterm.app.nightly`, Release is `com.cmuxterm.app` for both, tagged Debug
/// builds share `com.cmuxterm.app.debug.<tag>`), and the removed listener reused them on purpose
/// ("one bundle id keeps one identity"). This app cannot tell its leftovers from classic cmux's
/// live identity there, so it never deletes them.
public nonisolated struct PhoneAccessLeftovers: Sendable {
    /// The removed `PhoneAccessMigration.doneKey`.
    static let migratedKey = "cmux.phoneAccess.migrated.v1"

    /// The defaults suite to clean; nil is this app's own standard domain. Tests pass a suite.
    let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    /// Deletes the leftovers on a background task. Its value is the keys it deleted (empty when
    /// an earlier launch already did).
    @discardableResult
    public func cleanUpInBackground() -> Task<[String], Never> {
        // task-owner: one defaults lookup and at most one delete, off the main thread; ends at once
        Task.detached(priority: .utility) { [self] in cleanUp() }
    }

    private func cleanUp() -> [String] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        guard defaults.object(forKey: Self.migratedKey) != nil else { return [] }
        defaults.removeObject(forKey: Self.migratedKey)
        return [Self.migratedKey]
    }
}
