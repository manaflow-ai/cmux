import Network

/// Network restorations from `NWPathMonitor`: an unsatisfied path that turns
/// satisfied. A path that is already satisfied when the wait starts is not a
/// restoration, so a server that keeps failing on a working network does not
/// re-arm the loop at once.
public struct PathMonitorAuthNetworkRestorations: AuthNetworkRestorations {
    /// Creates the observer; each wait starts and stops its own monitor.
    public init() {}

    public func waitForRestoration() async {
        var sawUnusablePath = false
        for await path in NWPathMonitor() {
            if Task.isCancelled { return }
            if path.status != .satisfied {
                sawUnusablePath = true
            } else if sawUnusablePath {
                return
            }
        }
    }
}
