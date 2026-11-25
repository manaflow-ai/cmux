/// Whether a chat tab of this Mac reads as a Cloud chat in the tab strip (cmux#51000). A Cloud chat started from the New Tab
/// composer never moves to a Cloud machine's pane: this Mac's tab sends, shows the start's card, then shows the chat in place
/// (``CloudFrontedChats``, cmux#47677). Its pane's daemon is this Mac's, so the machine badge that marks a chat in a Cloud
/// machine's pane (`TabItem.setMachineBadge`) never drew; this marks it from the Send: starting, failed, and running.
/// Only the tab: the sidebar row keeps its own rules (Austin 2026-11-22: "we shouldnt show the cloud workspace in the left sidebar").
public nonisolated struct CloudChatTabMark: Equatable, Sendable {
    /// The Cloud machine the chat runs on, once it shows in place (its color pick colors the cloud); nil while it starts or after a failure.
    public var machine: String?

    public init(machine: String?) { self.machine = machine }

    /// The mark of an agent tab of this Mac: `frontedMachine`, the machine of the Cloud chat it shows in place; `sentToCloud`, its Send
    /// started a Cloud chat that is starting or failed (``AgentCloudStartTitles/sentToCloud(_:)``), from the New Tab page or a new chat's
    /// composer; `localSession`, it runs a chat of its own here (a later local Send after a failed start: a local chat, with no cloud).
    public static func mark(agent: Bool, frontedMachine: String?, sentToCloud: Bool, localSession: Bool) -> Self? {
        guard agent else { return nil }
        if let frontedMachine { return Self(machine: frontedMachine) }
        return sentToCloud && !localSession ? Self(machine: nil) : nil
    }
}
