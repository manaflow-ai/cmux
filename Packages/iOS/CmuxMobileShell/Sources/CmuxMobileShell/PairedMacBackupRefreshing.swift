/// A paired-Mac store that can re-pull the authoritative backup on demand,
/// instead of only once per launch at sign-in.
public protocol PairedMacBackupRefreshing: Sendable {
    /// Force a backup re-fetch and LWW merge for the signed-in scope.
    func refreshFromBackup(stackUserID: String?) async

    /// Same as ``refreshFromBackup(stackUserID:)`` and reports whether the merge
    /// wrote any row into the local store. Reads no longer wait for the restore
    /// (a scope with rows on disk is served at once), so a consumer that
    /// published from disk uses this to reload only when the merge changed
    /// something, instead of paying a read on every refresh.
    @discardableResult
    func refreshFromBackupReportingChange(stackUserID: String?) async -> Bool

    /// Cancel every in-flight restore or refresh for sign-out/account switches.
    func cancelInFlightRestores() async
}

public extension PairedMacBackupRefreshing {
    /// Stores without change accounting refresh and report no change.
    @discardableResult
    func refreshFromBackupReportingChange(stackUserID: String?) async -> Bool {
        await refreshFromBackup(stackUserID: stackUserID)
        return false
    }
}
