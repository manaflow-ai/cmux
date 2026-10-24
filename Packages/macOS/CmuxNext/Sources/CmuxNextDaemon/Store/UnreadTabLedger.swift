public import Observation

/// The store's unread tabs, counted as they change instead of walked on each read.
///
/// The badge and the sidebar read every workspace's unread count on each model change. The count
/// was a walk of the workspace's screens, panes and tabs, and the app-wide count walked every
/// workspace: O(all tabs) per read, and an observation of every tab's notification (sweep
/// 2026-10-23: `NotificationCenterService.unreadCount`, 53 ms of main thread on one STRESS Close
/// Pane). The ledger keeps each workspace's count (``WorkspaceModel/unreadTabCount``) and the
/// unread conversation tabs current from the only writes that change them: a tab indexed or
/// dropped (``StoreIndex``), and a tab's notification, pending read or conversation changing
/// (``TabModel``'s observers). Each costs O(1).
@Observable @MainActor
public final class UnreadTabLedger {
    /// The `conv_` ids of unread conversation tabs, with how many tabs show each.
    public private(set) var conversations: [String: Int] = [:]

    private struct Entry {
        weak var workspace: WorkspaceModel?
        var unread: Bool
        var conversation: String?
    }

    @ObservationIgnored private var entries: [ObjectIdentifier: Entry] = [:]
    /// How many times a count changed (tests: a change that leaves the count changes nothing).
    @ObservationIgnored private(set) var changes = 0

    init() {}

    /// Counts `tab` in `workspace` (its workspace now: a moved tab is tracked again).
    func track(_ tab: TabModel, in workspace: WorkspaceModel?) {
        untrack(tab)
        tab.unreadLedger = self
        let entry = Entry(workspace: workspace, unread: tab.hasUnread, conversation: Self.conversation(of: tab))
        entries[ObjectIdentifier(tab)] = entry
        apply(entry, sign: 1)
    }

    /// Stops counting `tab` (it left the store).
    func untrack(_ tab: TabModel) {
        guard let entry = entries.removeValue(forKey: ObjectIdentifier(tab)) else { return }
        if tab.unreadLedger === self { tab.unreadLedger = nil }
        apply(entry, sign: -1)
    }

    /// `tab`'s notification, pending read or conversation changed.
    func tabChanged(_ tab: TabModel) {
        let key = ObjectIdentifier(tab)
        guard let old = entries[key] else { return }
        let unread = tab.hasUnread, conversation = Self.conversation(of: tab)
        guard unread != old.unread || conversation != old.conversation else { return }
        apply(old, sign: -1)
        let new = Entry(workspace: old.workspace, unread: unread, conversation: conversation)
        entries[key] = new
        apply(new, sign: 1)
    }

    /// Drops every count (a snapshot indexes the whole tree again).
    func reset() {
        for entry in entries.values { apply(entry, sign: -1) }
        entries.removeAll()
    }

    private func apply(_ entry: Entry, sign: Int) {
        guard entry.unread else { return }
        changes += 1
        if let workspace = entry.workspace { workspace.unreadTabCount += sign }
        if let conversation = entry.conversation {
            let count = (conversations[conversation] ?? 0) + sign
            conversations[conversation] = count > 0 ? count : nil
        }
    }

    private static func conversation(of tab: TabModel) -> String? {
        tab.kind == .conversation ? tab.conversation?.conversation : nil
    }
}
