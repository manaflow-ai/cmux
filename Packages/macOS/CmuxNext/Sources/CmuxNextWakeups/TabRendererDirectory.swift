import CmuxNextCompat

/// The browser tabs and their renderers, published by the App on the main actor and read from any
/// thread: the busy watchdog names the tabs of a busy renderer off the main thread,
/// without waiting for it. The App updates one tab when its renderers may have changed (it mounts, its
/// load phase changes) and drops the tabs it closed, as Chrome's performance manager keeps its
/// page-to-process graph from events and reads it off the UI thread
/// (components/performance_manager/graph/page_node_impl.cc, process_node_impl.cc).
public final class TabRendererDirectory: Sendable {
    private let tabs = Mutex<[String: ProcessUsage.TabRenderers]>([:])

    /// An empty directory.
    public init() {}

    /// Records `tab`, replacing what its id had.
    public func update(_ tab: ProcessUsage.TabRenderers) {
        tabs.withLock { $0[tab.tab] = tab }
    }

    /// Drops every tab whose id is not in `ids` (the App's open tabs).
    public func keep(only ids: Set<String>) {
        tabs.withLock { tabs in tabs = tabs.filter { ids.contains($0.key) } }
    }

    /// Every recorded tab, ordered by id.
    public func snapshot() -> [ProcessUsage.TabRenderers] {
        tabs.withLock { Array($0.values) }.sorted { $0.tab < $1.tab }
    }
}
