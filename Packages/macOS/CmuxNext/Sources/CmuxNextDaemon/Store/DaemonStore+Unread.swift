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

    /// The workspace list changed from `old`: the workspaces that joined report to this store and add their counts,
    /// the ones that left take theirs out. O(changed) adds: the common head and tail of the two lists (a Cmd-N, a close,
    /// a move) are skipped by identity, and a workspace in both changed spans (a move) keeps its count. Invariant: a
    /// workspace whose `unreadStore` is this store is summed in ``unreadTotals`` with its `summedContribution`.
    func adoptUnread(from old: [WorkspaceModel]) {
        for workspace in workspaces where workspace.unreadStore !== self { workspace.unreadStore = self }
        recountUnread()
    }

    func unreadContributionChanged(from old: UnreadTotals, to new: UnreadTotals) { recountUnread() }

    /// BEFORE (measurement only): the old full re-sum.
    func recountUnread() {
        var totals = UnreadTotals()
        for workspace in workspaces {
            unreadWorkspaceVisits += 1
            totals.add(workspace.unreadContribution)
        }
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
            if workspace.markedUnread { totals.markedWorkspaces += 1 }
        }
        return totals
    }
}
