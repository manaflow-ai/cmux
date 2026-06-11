import CmuxSidebarInterpreterClient
import Foundation

/// Parks the most recent render-worker client across sidebar unmounts so
/// toggling the sidebar (or switching providers away and back) reattaches to
/// the warm worker and its cached remote context instead of paying a fresh
/// process spawn + first interpret + render (~1s of blank sidebar).
@MainActor
public final class RenderWorkerClientPool {
    public static let shared = RenderWorkerClientPool()

    private var parked: RenderWorkerClient?

    private init() {}

    /// Returns the parked client when one exists, otherwise a fresh
    /// re-exec-self client. A reclaimed client's surface adopts the cached
    /// remote context synchronously, so the last rendered frame shows
    /// immediately while the next scene refreshes it.
    public func acquire() -> RenderWorkerClient {
        if let parked {
            self.parked = nil
            return parked
        }
        return RenderWorkerClient.reexecingCurrentBinary()
    }

    /// Parks one client for the next mount. The slot is bounded at one: a
    /// newcomer while the slot is occupied is shut down, so at most one warm
    /// worker idles while no custom sidebar is mounted.
    public func park(_ client: RenderWorkerClient) {
        guard parked == nil else {
            Task { await client.shutdown() }
            return
        }
        parked = client
    }
}
