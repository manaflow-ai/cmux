import CmuxNextDaemon
import CmuxNextDaemonService

/// Mark Tab Unread (`tab-mark-unread-v1`): a durable flag on the tab record in
/// the daemon (`tab.update {marked_unread}`), apart from notification markers,
/// so any tab can be marked whether or not it has a notification. Every client
/// shows it as the tab's unread dot (and the workspace row's dot); a client
/// clears it when the person views the tab (``entered(_:previous:)``).
/// Toggle Unread, the tab menu's Mark Tab Unread and the notifications
/// panel's row verb all run ``toggle(_:pane:context:)``.
@MainActor
enum TabUnreadMark {
    /// What a toggle does to a tab.
    enum Step: Equatable {
        /// The tab shows unread (a notification, the mark, or both): read it.
        case read
        /// The tab shows read: mark it unread.
        case markUnread
    }

    /// The toggle's step for a tab that shows `showsUnread`.
    static func step(showsUnread: Bool) -> Step { showsUnread ? .read : .markUnread }

    /// Toggles `tab`: reads its notification and clears its mark when it shows
    /// unread, else marks it unread. Throws the refusal when the tab's daemon
    /// cannot keep the mark (an older daemon than the app: restart it).
    static func toggle(_ tab: TabModel, pane: PaneModel, context: AppActionContext) throws {
        let daemon = context.services.daemon(for: pane)
        switch step(showsUnread: tab.showsUnread) {
        case .read:
            if tab.hasUnread { try NotificationHandlers.acknowledge([tab.surface], context) }
            if tab.markedUnread { try set(false, tab: tab, daemon: daemon) }
        case .markUnread:
            try set(true, tab: tab, daemon: daemon)
        }
    }

    /// Sets or clears the mark through `daemon`, the one whose tree holds the
    /// tab. A clear on a daemon without the capability does nothing (it has no
    /// mark to clear); a mark there throws the missing-capability message.
    static func set(_ marked: Bool, tab: TabModel, daemon: DaemonService) throws {
        guard daemon.supports(DaemonCapability.tabMarkUnread.rawValue), daemon.store.servesStateResources,
              let resource = tab.resourceID else {
            guard marked else { return }
            throw ActionFailure(message: daemon.missingCapabilityMessage(DaemonCapability.tabMarkUnread.rawValue))
        }
        // Shown now; the record's echo confirms it, a refused write rolls it back.
        tab.expectMarkedUnread(marked)
        daemon.send("tab.update", onFailure: { _ in tab.dropExpectedMarkedUnread(marked) }) {
            try await $0.state.updateTabRecord(resource, markedUnread: marked)
        }
    }

    /// The ids of `viewed` tabs that `previous` did not hold: the tabs that came
    /// into view. A tab marked while the person looks at it keeps the mark
    /// until it leaves view and comes back, as a chat marked unread does.
    static func entered(_ viewed: [String], previous: Set<String>) -> [String] {
        viewed.filter { !previous.contains($0) }
    }
}
