/// What kind of hidden content a discard candidate is (p07-memory.md section 3.C). Every kind goes
/// through the one ``ContentDiscardPlanner``; the raw values are the names `debug.discards` reports.
package nonisolated enum ContentKind: String, Hashable, Sendable, CaseIterable {
    /// A browser page (CEF, WebKit and the other `BrowserTab` engines).
    case browser
    /// An agent chat page.
    case agentPage = "agent_page"
    /// A cmux page in a tab: Settings, History, Task Manager and the other internal pages.
    case internalPage = "internal_page"
    /// A page shown above the workspace (Home, the command center).
    case topPage = "top_page"
    /// A conversation tab's transcript.
    case conversation
    /// A terminal's render state.
    case terminalSurface = "terminal_surface"
    /// A hidden workspace's views.
    case parkedWorkspace = "parked_workspace"
    /// An overlay or prewarmed page.
    case overlayPage = "overlay_page"
    /// A right sidebar section.
    case sidebarSection = "sidebar_section"
}
