/// One open tab that may have asked for a cookie import (the App lists them;
/// ``CookieImportRequester`` picks the one the caller names).
public struct CookieImportCandidate: Sendable, Equatable {
    /// The tab id (`tab.focus` target).
    public var tabID: String
    /// The tab's title.
    public var title: String
    /// The workspace that holds the tab.
    public var workspace: String
    /// The agent session of an agent chat tab, nil for other tabs.
    public var agentSession: String?
    /// The terminal and terminal resource ids of a terminal tab, empty for other tabs.
    public var terminalIDs: [String]

    /// Creates a candidate.
    public init(tabID: String, title: String, workspace: String, agentSession: String?, terminalIDs: [String]) {
        self.tabID = tabID
        self.title = title
        self.workspace = workspace
        self.agentSession = agentSession
        self.terminalIDs = terminalIDs
    }
}
