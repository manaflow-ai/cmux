/// A Cloud machine as `cmux link start-chat plan` reads it (cmux-tui `link/start_chat_cli/pick.rs`): the pick takes
/// this person's free machine or one named for chats, never a teammate's or a lane-pool VM.
extension CloudMachine {
    /// This machine's entry in the plan's `machines`: its id, title, shown status (so a change on its way shows) and
    /// whether this App is connected to its daemon; its slug, maker and pause reason when known; and `chats`, its
    /// chat tabs, which only a connected daemon can count (nil leaves the key out).
    public func startChatPlanEntry(connected: Bool, chats: Int?) -> [String: Any] {
        var entry: [String: Any] = ["id": id, "title": title, "status": shownStatus.rawValue, "connected": connected]
        entry["slug"] = slug
        entry["created_by"] = createdBy
        entry["pause_reason"] = pauseReason?.rawValue
        entry["chats"] = chats
        return entry
    }
}

extension Collection<CloudMachine> {
    /// The ids of the store's machines the account's list did not name (`listed`): made since, kept for a pin (the
    /// plan's `stored`), never picked. Never one the server failed or is removing, which may stay in the store after
    /// the list dropped it: a pin or workspace on it then moves on.
    public func keptForPin(listed: Set<String>) -> [String] {
        filter { !listed.contains($0.id) && ![.failed, .destroyed, .deleting].contains($0.shownStatus) }.map(\.id)
    }
}
