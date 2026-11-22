public import CmuxNextDaemon

/// Splits whose new tab this app is making in one request (`new-frontend-browser-tab {split}`), until the reply.
/// The daemon's pane, holding the tab, usually arrives before the reply names the tab's surface: a tab in that
/// pane is the app's own new tab from then on, never a restored one (whose page reads its saved history first).
@MainActor public final class OpeningSplits {
    private var panes: Set<String> = []

    public init() {}

    /// Notes `split`, sent to `daemon`, until the returned closure runs (once the reply came or the request failed).
    public func begin(_ split: ConversationTabSplit, on daemon: DaemonService) -> @MainActor () -> Void {
        let key = Self.key(daemon.machineID, split.paneID)
        panes.insert(key)
        return { [weak self] in self?.panes.remove(key) }
    }

    /// Whether `surface` is a tab of `daemon` in the pane of a split under way.
    public func holds(_ surface: SurfaceID, on daemon: DaemonService) -> Bool {
        guard !panes.isEmpty, let pane = daemon.store.pane(containing: surface)?.resourceID?.rawValue else { return false }
        return panes.contains(Self.key(daemon.machineID, pane))
    }

    private static func key(_ machine: String, _ pane: String) -> String { machine + "\u{1F}" + pane }
}
