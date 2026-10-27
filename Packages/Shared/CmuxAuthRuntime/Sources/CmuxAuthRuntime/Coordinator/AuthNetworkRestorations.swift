/// The event that ends a retry loop's capped backoff early: the network path came back.
///
/// Chromium's sync scheduler does the same. At its capped backoff it retries
/// early when `NetworkChangeNotifier` reports a connection change
/// (`SyncSchedulerImpl::OnConnectionStatusChange`,
/// `components/sync/engine/sync_scheduler_impl.cc`).
public protocol AuthNetworkRestorations: Sendable {
    /// Returns when the network path next becomes usable after it was
    /// unusable, or when the calling task is cancelled.
    func waitForRestoration() async
}
