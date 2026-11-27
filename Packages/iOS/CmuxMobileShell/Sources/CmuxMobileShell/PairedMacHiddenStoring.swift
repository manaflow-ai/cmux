/// Durable device-local record of Macs the user explicitly hid.
///
/// This preference is intentionally separate from the paired-Mac backup
/// pending-delete outbox. Hiding never removes a SQLite row or creates a server
/// tombstone; it only filters the row on this iPhone until the user unhides it.
public protocol PairedMacHiddenStoring: Sendable {
    /// Load hidden Mac pairing ids for one account/team scope.
    func load(scope: String) async -> Set<String>

    /// Replace hidden Mac pairing ids for one account/team scope.
    func save(_ ids: Set<String>, scope: String) async

    /// Clear every remembered hidden id.
    func removeAll() async
}
