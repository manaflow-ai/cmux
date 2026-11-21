#if DEBUG
/// DEBUG ONLY: one way to lay out cmux with no Home (Lawrence, 2026-11-20: "get rid of home, and chiefs/other
/// stuff is kinda integrated together"; David Beyer, Nov 20: the Chief is a thread like the others, "threads
/// should all be threads", no multi-Chief panel, an option for a dedicated side panel).
enum ChiefNoHomeVariant: Int, CaseIterable {
    /// The Chief is the sidebar's first thread, its subagents under it; other Chiefs, group chats and DMs are
    /// ordinary threads in one Threads list above the workspaces. The picked thread fills the page.
    case threads = 1
    /// Every thread lives where it works: the Chief pinned on top, each workspace lists its agent chats and the
    /// Chief's subagents working there, and other Chiefs and group chats sit in the same list by recency.
    case nested = 2
    /// The workspace keeps the stage; the Chief is a side panel beside it, with one thread switcher for other
    /// Chiefs and group chats in its header. The sidebar has only workspaces.
    case sidePanel = 3

    var title: String {
        switch self {
        case .threads: "1. Chief is the first thread"
        case .nested: "2. Threads inside workspaces"
        case .sidePanel: "3. Chief side panel"
        }
    }

    var summary: String {
        switch self {
        case .threads: "No Home: the Chief tops the sidebar with its subagents; other Chiefs and chats are plain threads; the picked one fills the page."
        case .nested: "No Home: the Chief is pinned; every agent chat and subagent sits under the workspace it works in; chats are rows by recency."
        case .sidePanel: "No Home: the workspace keeps the stage; the Chief is a side panel; other Chiefs and chats are one switcher in its header."
        }
    }
}
#endif
