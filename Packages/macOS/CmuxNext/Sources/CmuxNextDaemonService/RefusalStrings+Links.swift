import Foundation

/// Reasons `link.open` and the Copy Link actions refuse (cmux:// deep
/// links). The link text is a format argument, never translated.
nonisolated extension RefusalStrings {
    /// A URL that is not a link in this build's scheme (another scheme, the
    /// sign-in callback, an unknown kind or a malformed id).
    public static func linkNotRecognized(_ url: String) -> String {
        format("handlers.refusal.linkNotRecognized", "not a link this build of cmux opens: %@", truncatedLinkText(url))
    }

    /// A link carried parameters cmux does not use: a name no link of its kind reads, a repeated
    /// one, or a hint whose value it cannot read. The link opened; this names what was left out.
    ///
    /// The names are whatever wrote the link — another app, a page, an agent's message — so they
    /// are shown the way the web page shows them (schemas/deeplinks/agent-link.json
    /// `ignoredOrder` leaves how to show them to each reader): each name inside the charset a
    /// parameter name may have and cut to ``shownNameLimit``, at most ``shownNames`` of them. A
    /// crafted link therefore cannot put its own sentence, newlines or writing-direction marks
    /// into cmux's own chrome.
    ///
    /// - Parameters:
    ///   - names: The ignored names, as the link wrote them.
    ///   - used: The names of the parameters the link did use (`DeepLink.usedParameters`). A
    ///     stray name shown as one of these is dropped unsaid, as the page drops it: `?host%20=x`
    ///     beside `?host=big-red` would otherwise deny a parameter the link carries.
    /// - Returns: The notice, or nil when nothing is left to name.
    public static func linkParametersIgnored(_ names: [String], used: Set<String> = []) -> String? {
        // Each name once, counted on what is shown rather than on what the link wrote, as the
        // page counts it: `?host%20=x&host%09=y` is one name here, and two names with nothing
        // printable left are one `?`.
        var seen: Set<String> = []
        let shown = names.map(displayedParameterName)
            .filter { !used.contains($0) && seen.insert($0).inserted }
            .prefix(shownNames)
        guard !shown.isEmpty else { return nil }
        return format("handlers.refusal.linkParametersIgnored",
                      "opened the link and ignored parameters it doesn't use: %@",
                      truncatedLinkText(shown.joined(separator: ", ")))
    }

    /// How many ignored names a refusal names, as the page names eight.
    static let shownNames = 8

    /// The most of one ignored name a refusal shows.
    static let shownNameLimit = 32

    /// `name` with everything a parameter name cannot hold dropped and cut to ``shownNameLimit``
    /// characters; `?` when that leaves nothing, so an unprintable name is still counted.
    static func displayedParameterName(_ name: String) -> String {
        let kept = name.filter { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber || character == "." || character == "_"
                || character == "-"
        }
        return kept.isEmpty ? "?" : String(kept.prefix(shownNameLimit))
    }

    /// The most of an unrecognized link's text a refusal shows: it comes
    /// from another app, a page or a script, so it is capped.
    static let linkTextLimit = 200

    /// `text` cut to ``linkTextLimit`` characters, with an ellipsis when cut.
    static func truncatedLinkText(_ text: String) -> String {
        text.count > linkTextLimit ? String(text.prefix(linkTextLimit)) + "…" : text
    }

    /// The link's target is closed, deleted, or on a machine that is not connected.
    public static var linkTargetGone: String {
        text("handlers.refusal.linkTargetGone", "the linked item is gone: it was closed or deleted, or its machine isn't connected")
    }

    /// A cloud group link (`cmux://group/grp_…`) whose group none of the workspaces of is open on
    /// this Mac (plans/cmux-next/cloud-groups-DESIGN.md).
    public static var cloudGroupNotOpenHere: String {
        text("handlers.refusal.cloudGroupNotOpenHere", "none of this cloud group's workspaces is open on this Mac")
    }

    /// A `cmux://agent/…` link while Debug Settings turned agent links off.
    public static var agentLinksOff: String {
        text("handlers.refusal.agentLinksOff", "agent links are turned off in this build")
    }

    /// A nightly pane or tab link: its workspace opened, the item itself has no counterpart here.
    public static var linkItemNotFound: String {
        text("handlers.refusal.linkItemNotFound", "opened the workspace, but the linked pane or tab couldn't be found")
    }

    /// Copy Tab Link on an agent tab that is still a new chat.
    public static var agentTabHasNoSession: String {
        text("handlers.refusal.agentTabHasNoSession", "this chat has no link yet: send it a message first")
    }

    /// An agent chat tab in a pane whose daemon lacks `agent-session-tabs-v1`.
    public static var agentTabsUnsupported: String {
        text("handlers.refusal.agentTabsUnsupported", "this machine's cmux-tui cannot hold agent chat tabs yet: update it")
    }

    /// Duplicate Tab on an agent chat tab whose acpmux session runs on another Mac.
    public static var agentTabOtherHost: String {
        text("handlers.refusal.agentTabOtherHost", "this chat runs on another Mac")
    }

    /// A chat of this Mac (its session, an outside chat it resumes, a past chat of its list) in a
    /// tab of another machine, or the reverse: a session never leaves its machine (cx-k21v).
    public static var agentTabMachineMismatch: String {
        text("handlers.refusal.agentTabMachineMismatch", "this chat runs on another machine: it cannot open in this tab")
    }

    /// `app_agent_open` with another machine's host: the same session opens without the host (through
    /// the peer) or from that machine's workspace (coord-deputy 2026-10-20).
    public static func agentTabRunsOnHost(_ host: String) -> String {
        format("handlers.refusal.agentTabRunsOnHost", "this session runs on %@: open it without a host, or from that machine's workspace", host)
    }

    /// The store refused or failed a new agent chat tab; the tab shown at once goes away.
    public static var agentTabCreateFailed: String {
        text("handlers.refusal.agentTabCreateFailed", "the agent chat tab could not be created: see the app log")
    }

    /// A chat change in a tab lost a compare-and-swap: another device changed it first.
    public static var agentTabSessionConflict: String {
        text("handlers.refusal.agentTabSessionConflict", "the chat in this tab changed on another device: it keeps that chat after relaunch")
    }

    /// A new agent chat tab in a pane whose daemon is not connected (nothing queues).
    public static var agentTabsDisconnected: String {
        text("handlers.refusal.agentTabsDisconnected", "this machine's cmux-tui is not connected: the agent chat tab was not opened")
    }

    /// A chat change in a tab that did not reach the store (not a conflict).
    public static var agentTabSessionNotSaved: String {
        text("handlers.refusal.agentTabSessionNotSaved", "the chat change in this tab was not saved: see the app log")
    }

    /// Copy Link on an object its daemon gives no durable resource id.
    public static var noLinkID: String {
        text("handlers.refusal.noLinkID", "this item has no link yet: cmux-tui on its machine doesn't give it a durable id")
    }
}
