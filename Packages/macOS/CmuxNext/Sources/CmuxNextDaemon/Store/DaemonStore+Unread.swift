/// The unread counts (``UnreadTotals``): the Dock badge, the notification center and the
/// sidebar's notification row read them on every store change they observe.
extension DaemonStore {
    /// The Dock badge's count: the workspaces' unread tabs and Home's unread conversations that no
    /// tab counts (``UnreadTotals/badge(homeUnread:)``).
    /// - Parameter homeUnread: Home's unread conversation ids.
    /// - Returns: The count to show.
    public func unreadBadge(homeUnread: [String] = []) -> Int {
        unreadTotals.badge(homeUnread: homeUnread)
    }

    /// The workspace list changed: each workspace reports to this store, which sums them again.
    func adoptUnread() {
        for workspace in workspaces where workspace.unreadStore !== self { workspace.unreadStore = self }
        recountUnread()
    }

    /// Sums the workspaces' counts (integer adds over the list, no tab read) and assigns
    /// ``unreadTotals`` when the sum changed.
    func recountUnread() {
        var totals = UnreadTotals()
        for workspace in workspaces { totals.add(workspace.unreadContribution) }
        if totals != unreadTotals { unreadTotals = totals }
    }

    /// Debug builds' check, from the mirror check (at most once a second): the stored counts equal a
    /// count from every tab, so a write path that skips the counts is reported, never a silent drift.
    func verifyUnreadTotals() {
        #if DEBUG
        let recounted = recountedUnreadTotals()
        guard recounted != unreadTotals else { return }
        reportMirrorViolation("unread totals drifted: stored \(unreadTotals.tabs) tabs, \(unreadTotals.conversations.count) conversations; "
            + "counted \(recounted.tabs) tabs, \(recounted.conversations.count) conversations")
        #endif
    }

    /// The totals counted from every tab of every workspace (the check of the stored totals in tests
    /// and in debug builds' mirror check).
    public func recountedUnreadTotals() -> UnreadTotals {
        var totals = UnreadTotals()
        for workspace in workspaces {
            var count = 0
            if workspace.screens.isEmpty {
                count = workspace.daemonUnreadCount ?? 0
            } else {
                for screen in workspace.screens {
                    for pane in screen.panes {
                        for tab in pane.tabs {
                            unreadTabReads += 1
                            guard tab.hasUnread else { continue }
                            count += 1
                            if tab.kind == .conversation, let id = tab.conversation?.conversation { totals.conversations[id, default: 0] += 1 }
                        }
                    }
                }
            }
            totals.tabs += count == 0 && workspace.markedUnread ? 1 : count
        }
        return totals
    }
}
