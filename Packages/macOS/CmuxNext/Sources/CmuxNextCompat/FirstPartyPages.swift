import Foundation

/// The first-party pages the app ships, by page id (`cmux-page://<id>`). One table for the page
/// host's trust and CSP (CmuxNextPages `PageID.firstParty`) and for the page origins the app's
/// daemon page listener admits (CmuxNextDaemonService, which does not link CmuxNextPages):
/// every first-party page may open its own daemon WebSocket and gets its page id from its Origin
/// (cmux-tui spec/page-router.md; cx-hnmbt.10).
public nonisolated struct FirstPartyPages {
    public nonisolated init() {}

    /// A page missing here gets the strict CSP whatever its descriptor asks for: `cmux.home-channels`
    /// lost its `connect-src` and WebKit refused its daemon WebSocket ("The operation is insecure",
    /// cx-hnmbt.6).
    public static let ids: Set<String> = [
        "cmux.history", "cmux.apps", "cmux.settings", "cmux.cloud", "cmux.agent", "cmux.keybindings",
        "cmux.diff", "cmux.markdown", "cmux.icon-picker", "cmux.passwords", "cmux.editor", "cmux.chief-inspector", "cmux.debug-settings",
        "cmux.home-channels", "cmux.changelog",
    ]

    /// The Origin of every first-party page (`cmux-page://cmux.history`, ...), sorted, so the
    /// owner's argv is the same on every launch.
    public static let origins: [String] = ids.sorted().map { "cmux-page://" + $0 }
}
