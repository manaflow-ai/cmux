/// The event that re-arms a retry loop that gave up: the network path came back.
///
/// Chromium's sync scheduler does the same. After its backoff it waits for
/// `NetworkChangeNotifier` to report a connection change
/// (`SyncSchedulerImpl::OnConnectionStatusChange`,
/// `components/sync/engine/sync_scheduler_impl.cc`) instead of polling.
public protocol AuthNetworkRestorations: Sendable {
    /// Returns when the network path next becomes usable after it was
    /// unusable, or when the calling task is cancelled.
    func waitForRestoration() async
}
