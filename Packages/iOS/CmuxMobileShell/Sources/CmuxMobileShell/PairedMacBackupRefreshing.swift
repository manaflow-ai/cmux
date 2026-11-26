/// A paired-Mac store that can re-pull the authoritative backup on demand,
/// instead of only once per launch at sign-in.
public protocol PairedMacBackupRefreshing: Sendable {
    /// Force a backup re-fetch and LWW merge for the signed-in scope.
    func refreshFromBackup(stackUserID: String?) async

    /// Cancel every in-flight restore or refresh for sign-out/account switches.
    func cancelInFlightRestores() async
}
