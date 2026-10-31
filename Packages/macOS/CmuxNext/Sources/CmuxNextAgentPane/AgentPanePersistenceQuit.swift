public import CmuxNextWakeups

/// The agent panes' last accepted save, before browser shutdown can suspend or end the process.
@MainActor
public struct AgentPanePersistenceQuit {
    private let drafts: AgentUnsentDrafts?
    private let anchors: AgentPaneScrollAnchors?
    private let work: BackgroundWork?

    /// The state owners and lanes from the app's composition root; nil covers quit before setup.
    public init(drafts: AgentUnsentDrafts?, anchors: AgentPaneScrollAnchors?, work: BackgroundWork?) {
        self.drafts = drafts
        self.anchors = anchors
        self.work = work
    }

    /// Drains accepted saves under the caller's existing quit deadline.
    public func drain() async {
        // Both owners are main-actor isolated: seal them in this turn, before the first suspension.
        // WebKit can keep delivering messages while the lanes drain or CEF stops; those are refused.
        drafts?.finishSaving()
        anchors?.finishSaving()
        await drafts?.identitiesSettled()
        await work?.shutdown()
    }
}
