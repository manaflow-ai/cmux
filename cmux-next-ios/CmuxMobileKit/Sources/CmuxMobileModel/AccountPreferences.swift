import Foundation

/// The signed-in account's own preferences (`AppStore.isAccountPreference`:
/// setup done, the remembered Mac per team, last tab per workspace, recent
/// folders, Mac filters, team colors) plus where the app was last open.
///
/// While an account is signed in they live under their usual keys, where
/// every reader finds them. Sign-out moves them into that account's own
/// record (`cmuxMobile.account.<user id>`), so the next account starts clean and the
/// same account, signing in again, gets them back: no setup again, the same
/// Mac and workspace (verify/persistence.md). None of them is a secret: ids,
/// folder paths, colors and flags.
public final class AccountPreferences: @unchecked Sendable { // crash-allow: UserDefaults is thread-safe
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static let standard = AccountPreferences()

    /// The user whose preferences are under the live keys now.
    static let currentKey = "cmuxMobile.account.current"
    static func recordKey(_ userID: String) -> String { "cmuxMobile.account.\(userID)" }

    /// Keys that move with the account. The auth runtime owns
    /// `cmuxMobile.auth.selectedTeam` (it clears it on sign-out and the service
    /// restores it), so it stays out.
    public static func moves(_ key: String) -> Bool {
        guard key != "cmuxMobile.auth.selectedTeam" else { return false }
        return AppStore.isAccountPreference(key) || key == "cmuxMobile.lastOpenLocation"
    }

    private var liveKeys: [String] {
        defaults.dictionaryRepresentation().keys.filter(Self.moves)
    }

    /// The user whose preferences are live, if any.
    public var currentUserID: String? {
        guard let value = defaults.string(forKey: Self.currentKey), !value.isEmpty else { return nil }
        return value
    }

    /// Whether this build has ever recorded an account here (signed in or out).
    /// False only on the first launch after an older build, or a fresh install.
    public var hasRecord: Bool { defaults.string(forKey: Self.currentKey) != nil }

    /// Sign-in (and every launch while signed in): makes `userID`'s preferences live.
    ///
    /// - Another account's live preferences (a sign-out that never finished)
    ///   are put away under that account first.
    /// - After a sign-out, whatever was written to the live keys since (a view
    ///   saving while it faded out) belongs to nobody and is dropped.
    /// - With no record at all (the first launch after an older build), the
    ///   live preferences already belong to the signed-in account: earlier
    ///   builds deleted them on every sign-out. They are kept as `userID`'s.
    public func activate(userID: String) {
        let marker = defaults.string(forKey: Self.currentKey)
        if marker == userID { return }
        if let current = currentUserID { stash(userID: current) }
        if marker != nil {
            for key in liveKeys { defaults.removeObject(forKey: key) }
        }
        if let record = defaults.dictionary(forKey: Self.recordKey(userID)) {
            for key in liveKeys { defaults.removeObject(forKey: key) }
            for (key, value) in record where Self.moves(key) { defaults.set(value, forKey: key) }
            defaults.removeObject(forKey: Self.recordKey(userID))
        }
        defaults.set(userID, forKey: Self.currentKey)
    }

    /// Sign-out: puts the live preferences away under `userID` (the account
    /// signing out), clears the live keys, and marks that nobody owns them.
    public func stash(userID: String) {
        var record: [String: Any] = [:]
        for key in liveKeys {
            if let value = defaults.object(forKey: key) { record[key] = value }
            defaults.removeObject(forKey: key)
        }
        if record.isEmpty {
            defaults.removeObject(forKey: Self.recordKey(userID))
        } else {
            defaults.set(record, forKey: Self.recordKey(userID))
        }
        defaults.set("", forKey: Self.currentKey)
    }

    /// A launch while signed out. With no record (the first launch after an
    /// older build whose session has since ended without a sign-out), the live
    /// preferences belong to no one who can be told apart: they are dropped,
    /// so the next account never inherits them. Returns whether that happened
    /// (the caller then discards the older build's device secrets too).
    @discardableResult
    public func settleSignedOut() -> Bool {
        guard !hasRecord else { return false }
        for key in liveKeys { defaults.removeObject(forKey: key) }
        defaults.set("", forKey: Self.currentKey)
        return true
    }

    /// `key`'s value for `userID` without making anything live: the live value
    /// when the account is live (or no account was ever recorded), else its record.
    public func value(_ key: String, userID: String) -> Any? {
        let marker = defaults.string(forKey: Self.currentKey)
        if marker == userID || marker == nil { return defaults.object(forKey: key) }
        return defaults.dictionary(forKey: Self.recordKey(userID))?[key]
    }

    /// Account deletion: the account's record goes (live keys are cleared by sign-out).
    public func forget(userID: String) {
        defaults.removeObject(forKey: Self.recordKey(userID))
    }
}
