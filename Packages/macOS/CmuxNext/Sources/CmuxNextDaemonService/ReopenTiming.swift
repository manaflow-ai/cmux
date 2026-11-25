/// The last reopen of a closed item (`DaemonClosedHistory.reopen`): time to the daemon's reply and to
/// the store holding the reopened objects (`debug.filepages`). Moved from the App's CloseUndoToasts.
public struct ReopenTiming: Sendable {
    public var id: String
    public var tabs: [String]
    public var reply: Duration
    public var applied: Duration?
    public var tabsInStoreAtApplied: Bool?
    public var tabsArrived: Duration?

    /// A reopen the daemon answered after `reply`.
    public init(id: String, tabs: [String], reply: Duration) {
        self.id = id
        self.tabs = tabs
        self.reply = reply
    }
}
