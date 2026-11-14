import Foundation

/// The first-party pages the app ships, by page id (`cmux-page://<id>`). One table for the page
/// host's trust and CSP (CmuxNextPages `PageID.firstParty`) and for the page origins the app's
/// daemon page listener admits (CmuxNextDaemonService, which does not link CmuxNextPages):
/// every first-party page may open its own daemon WebSocket and gets its page id from its Origin
/// (cmux-tui spec/page-router.md; cx-hnmbt.10).
public nonisolated struct FirstPartyPages {
    public nonisolated init() {}

    /// Every production document written by `build-pages-web.sh`. This is deliberately
    /// broader than `ids`: the daemon trust table contains only pages that open a daemon
    /// WebSocket, while every built page must be able to load the shared JavaScript graph.
    /// Keep this list in the compatibility module so native adapters agree without widening
    /// daemon permissions.
    public static let shippedIDs: Set<String> = [
        "cmux.agent-board", "cmux.apps", "cmux.artifacts", "cmux.bookmarks", "cmux.changelog",
        "cmux.chief-inspector", "cmux.chief-usage", "cmux.chief-views", "cmux.cloud",
        "cmux.cloud-progress", "cmux.coderouter", "cmux.debug-settings", "cmux.feed",
        "cmux.files", "cmux.github", "cmux.group-editor", "cmux.history",
        "cmux.home-channels", "cmux.home-messages", "cmux.icon-picker", "cmux.import-history",
        "cmux.keybindings", "cmux.machines", "cmux.mobile-pairing", "cmux.onboarding",
        "cmux.passwords", "cmux.server-cards", "cmux.settings", "cmux.setup-card",
        "cmux.stash", "cmux.stats", "cmux.task-manager", "cmux.tasks",
        "cmux.site-settings", "cmux.site-data", "cmux.certificate", "cmux.cookie-import",
        "cmux.sidebar-chats",
    ]

    /// A page missing here gets the strict CSP whatever its descriptor asks for: `cmux.home-channels`
    /// lost its `connect-src` and WebKit refused its daemon WebSocket ("The operation is insecure",
    /// cx-hnmbt.6).
    public static let ids: Set<String> = [
        "cmux.bookmarks",
        "cmux.history", "cmux.apps", "cmux.settings", "cmux.cloud", "cmux.agent", "cmux.keybindings",
        "cmux.diff", "cmux.markdown", "cmux.icon-picker", "cmux.passwords", "cmux.editor", "cmux.chief-inspector", "cmux.debug-settings",
        "cmux.home-channels", "cmux.home-messages", "cmux.changelog", "cmux.feed",
        "cmux.site-settings", "cmux.site-data", "cmux.certificate",
        "cmux.cookie-import",
    ]

    /// The Origin of every first-party page (`cmux-page://cmux.history`, ...), sorted, so the
    /// owner's argv is the same on every launch.
    public static let origins: [String] = ids.sorted().map { "cmux-page://" + $0 }
}
