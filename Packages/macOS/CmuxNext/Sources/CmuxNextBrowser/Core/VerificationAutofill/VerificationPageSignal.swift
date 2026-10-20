public import Foundation

/// A tab's top frame waits for a verification email: it shows a field
/// marked `autocomplete="one-time-code"`, or text saying a code or link was
/// sent (DESIGN.md, "Page signal").
public nonisolated struct VerificationPageSignal: Sendable, Hashable {
    public let tab: BrowserTabID
    /// The top frame's URL when the wait started.
    public let pageURL: URL
    public let startedAt: Date
    /// An agent drives the tab: it never gets offers (as ``PasswordFillPolicy``).
    public let agentDriven: Bool

    public init(tab: BrowserTabID, pageURL: URL, startedAt: Date, agentDriven: Bool) {
        self.tab = tab
        self.pageURL = pageURL
        self.startedAt = startedAt
        self.agentDriven = agentDriven
    }
}
