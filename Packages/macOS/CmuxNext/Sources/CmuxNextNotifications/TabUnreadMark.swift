package import CmuxNextDaemon
package import CmuxNextDaemonService

/// Mark Tab Unread (`tab-mark-unread-v1`): a durable flag on the tab record in
/// the daemon (`tab.update {marked_unread}`), apart from notification markers,
/// so any tab can be marked whether or not it has a notification. Every client
/// shows it as the tab's unread dot (and the workspace row's dot); a client
/// clears it when the person views the tab (``entered(_:previous:)``).
/// Toggle Unread, the tab menu's Mark Tab Unread and the notifications
/// panel's row verb all run ``toggle(_:daemon:acknowledge:)``.
@MainActor
package enum TabUnreadMark {
    /// What a toggle does to a tab.
    package enum Step: Equatable {
        /// The tab shows unread (a notification, the mark, or both): read it.
        case read
        /// The tab shows read: mark it unread.
        case markUnread
    }

    /// The toggle's step for a tab that shows `showsUnread` (cmux-window-rules'
    /// `notification_notices_tab_unread_toggle`: only a tab that shows read is marked).
    package static func step(showsUnread: Bool) -> Step {
        let plan = NotificationNotices.tabUnreadToggle(showsUnread: showsUnread, hasUnread: false, markedUnread: false, attention: false,
                                                       attentionSupported: true, markSupported: true)
        return plan.steps == [.mark] ? .markUnread : .read
    }

    /// Toggles `tab`: reads its notification and clears its mark when it shows
    /// unread, else marks it unread. Throws the refusal when the tab's daemon
    /// cannot keep the mark (an older daemon than the app: restart it). Every
    /// write is validated up front (cmux-window-rules'
    /// `notification_notices_tab_unread_toggle`): a mixed-version daemon must not
    /// leave a notification acknowledged or a manual mark cleared when its
    /// conditional attention-clear capability is unavailable.
    /// `daemon` is the one whose tree holds the tab; `acknowledge` reads its notification.
    package static func toggle(_ tab: TabModel, daemon: DaemonService, acknowledge: () throws -> Void) throws {
        let plan = NotificationNotices.tabUnreadToggle(showsUnread: tab.showsUnread, hasUnread: tab.hasUnread, markedUnread: tab.markedUnread,
                                                       attention: tab.attention != nil, attentionSupported: attentionSupported(daemon),
                                                       markSupported: markSupported(tab, daemon: daemon))
        if let refuse = plan.refuse { throw ActionFailure(message: daemon.missingCapabilityMessage(capability(refuse))) }
        for step in plan.steps {
            switch step {
            case .acknowledge: try acknowledge()
            case .clearMark: try set(false, tab: tab, daemon: daemon)
            case .clearAttention: try clearAttention(tab: tab, daemon: daemon)
            case .mark: try set(true, tab: tab, daemon: daemon)
            }
        }
    }

    /// Sets or clears the mark through `daemon`, the one whose tree holds the
    /// tab. A clear on a daemon without the capability does nothing (it has no
    /// mark to clear); a mark there throws the missing-capability message.
    package static func set(_ marked: Bool, tab: TabModel, daemon: DaemonService) throws {
        switch NotificationNotices.markWrite(marked ? .mark : .clearMark, supported: markSupported(tab, daemon: daemon)) {
        case .nothing: return
        case let .refuse(missing): throw ActionFailure(message: daemon.missingCapabilityMessage(capability(missing)))
        case .send: break
        }
        guard let resource = tab.resourceID else { return }
        // A read: shown now and kept while the daemon is down or restoring; only its refusal rolls it back.
        guard marked else { return daemon.clearMarkedUnread(of: tab, resource: resource) }
        // Shown now; the record's echo confirms it, a refused write rolls it back.
        tab.expectMarkedUnread(marked)
        daemon.send("tab.update", onFailure: { _ in tab.dropExpectedMarkedUnread(marked) }) {
            try await $0.state.updateTabRecord(resource, markedUnread: marked)
        }
    }

    /// Mark as Read on a tab an agent marked (tab-attention-v1) drops that mark too: the person
    /// saw what the agent asked. A daemon without conditional-clear support refuses rather than
    /// risking an unconditional delayed clear.
    package static func clearAttention(tab: TabModel, daemon: DaemonService) throws {
        switch NotificationNotices.markWrite(.clearAttention, supported: attentionSupported(daemon)) {
        case .nothing: return
        case let .refuse(missing): throw ActionFailure(message: daemon.missingCapabilityMessage(capability(missing)))
        case .send: break
        }
        guard let resource = tab.resourceID, let request = tab.expectAttentionClear() else { return }
        daemon.clearAttention(request, of: tab, resource: resource)
    }

    /// The ids of `viewed` tabs that `previous` did not hold: the tabs that came
    /// into view. A tab marked while the person looks at it keeps the mark
    /// until it leaves view and comes back, as a chat marked unread does.
    package static func entered(_ viewed: [String], previous: Set<String>) -> [String] {
        NotificationNotices.entered(viewed, previous: previous)
    }

    /// `daemon` clears an agent's mark conditionally.
    private static func attentionSupported(_ daemon: DaemonService) -> Bool {
        daemon.supports(DaemonCapability.tabAttentionRequestID.rawValue) && daemon.store.servesStateResources
    }

    /// `daemon` keeps the mark for `tab`.
    private static func markSupported(_ tab: TabModel, daemon: DaemonService) -> Bool {
        daemon.supports(DaemonCapability.tabMarkUnread.rawValue) && daemon.store.servesStateResources && tab.resourceID != nil
    }

    /// The daemon capability a refusal names.
    private static func capability(_ missing: NotificationNotices.MarkCapability) -> String {
        switch missing {
        case .tabAttentionRequestId: DaemonCapability.tabAttentionRequestID.rawValue
        case .tabMarkUnread: DaemonCapability.tabMarkUnread.rawValue
        }
    }
}
