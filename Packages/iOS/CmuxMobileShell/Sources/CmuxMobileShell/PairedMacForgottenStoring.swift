/// Durable local record of Macs the user explicitly removed.
///
/// This is separate from the paired-Mac backup pending-delete outbox. The outbox
/// can clear once the server tombstone uploads, but the shell still needs a local
/// guard after relaunch so passive presence/registry route refreshes cannot
/// recreate a Mac the user forgot. A successful explicit pair/connect clears the
/// forgotten id.
public protocol PairedMacForgottenStoring: Sendable {
    /// Load forgotten Mac device ids for one account/team scope.
    func load(scope: String) async -> Set<String>

    /// Replace forgotten Mac device ids for one account/team scope.
    func save(_ ids: Set<String>, scope: String) async

    /// Clear every remembered forgotten id.
    func removeAll() async
}
