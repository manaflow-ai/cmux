import Foundation

/// Repository for the quit-confirmation mode, persisted in `UserDefaults`
/// under the catalog's `app.confirmQuit` key with a legacy fallback chain on
/// `app.warnBeforeQuit`.
///
/// Read semantics (kept verbatim from the legacy `QuitWarningSettings`
/// namespace; the two-key chain is wire format for existing users):
/// 1. A stored, recognized `confirmQuit` string wins.
/// 2. Otherwise, when the legacy boolean `warnBeforeQuitShortcut` was never
///    set, the default is ``ConfirmQuitMode/always``.
/// 3. Otherwise the legacy boolean maps `true` → ``ConfirmQuitMode/always``,
///    `false` → ``ConfirmQuitMode/never``.
///
/// Writes keep both keys in sync so downgrades and the legacy importer keep
/// working.
///
/// Isolation: a stateless `Sendable` struct, not an actor — the quit flow
/// reads synchronously on the main thread, the struct holds no mutable
/// state, and `UserDefaults` is documented thread-safe.
public struct QuitConfirmationStore: Sendable {
    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let keys = AppCatalogSection()

    /// Creates a store reading and writing the given defaults suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The effective quit-confirmation mode per the legacy fallback chain.
    public var confirmQuitMode: ConfirmQuitMode {
        if let mode = ConfirmQuitMode.decodeFromUserDefaults(
            defaults.object(forKey: keys.confirmQuitMode.userDefaultsKey)
        ) {
            return mode
        }
        guard keys.warnBeforeQuit.hasStoredValue(in: defaults) else {
            return keys.confirmQuitMode.defaultValue
        }
        return keys.warnBeforeQuit.value(in: defaults) ? .always : .never
    }

    /// Whether any quit confirmation is enabled (mode is not `never`).
    public var isEnabled: Bool {
        confirmQuitMode != .never
    }

    /// Whether the quit flow should show the confirmation dialog.
    ///
    /// Semantics are kept verbatim from the legacy `QuitWarningSettings`
    /// namespace: a prior in-session confirmation always skips the dialog,
    /// dev builds never warn, and otherwise ``confirmQuitMode`` decides
    /// (`dirtyOnly` consults `hasDirtyWorkspaces`).
    ///
    /// - Parameters:
    ///   - isQuitWarningConfirmed: Whether the user already confirmed the
    ///     quit warning earlier in this terminate flow.
    ///   - hasDirtyWorkspaces: Whether any workspace has unsaved/dirty state.
    ///   - isDevBuild: Whether this is a dev-flavor build (the app resolves
    ///     its build flavor; dev builds skip the warning entirely).
    public func shouldShowConfirmation(
        isQuitWarningConfirmed: Bool,
        hasDirtyWorkspaces: Bool,
        isDevBuild: Bool
    ) -> Bool {
        guard !isQuitWarningConfirmed else { return false }
        guard !isDevBuild else { return false }

        switch confirmQuitMode {
        case .always:
            return true
        case .dirtyOnly:
            return hasDirtyWorkspaces
        case .never:
            return false
        }
    }

    /// Persists `mode`, mirroring the legacy boolean key for downgrades.
    public func setMode(_ mode: ConfirmQuitMode) {
        keys.confirmQuitMode.set(mode, in: defaults)
        keys.warnBeforeQuit.set(mode != .never, in: defaults)
    }

    /// Convenience mapping of an on/off toggle onto ``setMode(_:)``:
    /// `true` → `always`, `false` → `never`.
    public func setEnabled(_ isEnabled: Bool) {
        setMode(isEnabled ? .always : .never)
    }
}
