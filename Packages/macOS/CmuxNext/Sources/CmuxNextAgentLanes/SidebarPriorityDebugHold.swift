#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSidebar
public import Observation

/// DEBUG ONLY: holds the Priority view's chat list read, for captures of ui-state-fixes M6
/// (`debug.sidebar_priority_hold`). While `held`, every window's real Priority feed reads as if no
/// chat list had come: it shows "Loading agent chats…", its own deadline
/// (`SidebarPriorityFeed.loadDeadline`) ends that in "Couldn't load agent chats." with Try Again,
/// and Try Again runs the feed's own retry (watches connect again, loading under a fresh
/// deadline). Released, the feed reads its real chat lists again: the chats, or "No agent chats
/// right now" once a store delivered an empty page. Nothing draws a panel the feed did not build.
/// Compiled out of Release.
@Observable @MainActor
public final class SidebarPriorityDebugHold {
    public static let shared = SidebarPriorityDebugHold()

    public init() {}

    /// The chat list read is held: no list was read.
    public var held = false
    /// What a feed last showed (`loading`, `failed`, `empty` or `list`), for the capture's readout.
    @ObservationIgnored public internal(set) var shown: String?

    nonisolated static func state(of panel: SidebarPriorityPanel) -> String {
        if !panel.entries.isEmpty { return "list" }
        if panel.loaded { return "empty" }
        return panel.loadFailed ? "failed" : "loading"
    }
}
#endif
