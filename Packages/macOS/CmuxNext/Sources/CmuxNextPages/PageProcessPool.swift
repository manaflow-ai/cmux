public import WebKit

/// The one WebKit process pool of the app: every page view, pooled page host and agent page uses
/// it (R81: WebKit lists the user-installed fonts once per pool, 25-38 ms of main-thread time per
/// new pool; a shared pool lists them once). Isolation between pages comes from each view's own
/// non-persistent website data store, never from a separate pool.
@MainActor
public enum PageProcessPool {
    public static let shared = WKProcessPool()

    #if DEBUG
    /// The claim bench's "before" mode: a new pool per view (the cost the shared pool removes).
    static var separatePoolsForBench = false
    #endif

    /// The pool a new page view uses.
    static var forNewView: WKProcessPool {
        #if DEBUG
        if separatePoolsForBench { return WKProcessPool() }
        #endif
        return shared
    }
}
