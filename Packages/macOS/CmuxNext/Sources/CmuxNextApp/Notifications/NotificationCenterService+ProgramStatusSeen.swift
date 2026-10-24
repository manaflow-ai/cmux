import AppKit
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import Observation

extension NotificationCenterService {
    /// What a viewed tab's arrivals need, pushed by observation of the viewed
    /// tabs, no poll and no settle re-run:
    /// - a `done` or `error` record that arrives while the user looks at its
    ///   tab (key window, cmux active) is seen at once;
    /// - an unread notification on a viewed tab is read at once, on every
    ///   path that marks it unread (an arrival, a held delivery, a resync),
    ///   when the dismissal policy reads on focus (`interacted(.focus)`; the
    ///   default `click` keeps it until the pane is clicked or typed in).
    /// Focus, typing, clicks and opens see the rest through `interacted`. An
    /// agent chat's turns are acpmux's (`unread`, cx-n8ou): its pane says
    /// whether it shows the chat.
    func followViewedProgramStatus(_ store: DaemonStore) -> Task<Void, Never> {
        Task { [weak self] in // task-owner: start(services:) keeps the handle in tasks
            for await _ in ObservationStream({ [weak self] in self?.viewedFacts(store) ?? ViewedTabsFacts(revision: 0, tabs: []) }) {
                guard let self else { return }
                let viewed = self.viewedTabs(store)
                for tab in viewed { self.interacted(.focus, tab: tab) }
                self.clearTabMarks(entering: viewed)
            }
        }
    }

    /// Clears the manual mark (Mark Tab Unread, `TabUnreadMark`) of each tab
    /// that came into view since the last pass. A tab marked while viewed
    /// keeps the mark until it is viewed again.
    func clearTabMarks(entering viewed: [TabModel]) {
        let entered = Set(TabUnreadMark.entered(viewed.map(\.id), previous: viewedTabIDs))
        viewedTabIDs = Set(viewed.map(\.id))
        guard let services else { return }
        for tab in viewed where tab.markedUnread && entered.contains(tab.id) {
            try? TabUnreadMark.set(false, tab: tab, daemon: services.daemon)
        }
    }

    /// What the rules follow: which tabs are viewed (`viewedRevision`, bumped
    /// when a window's settled focus changes), their OSC 7501 records and
    /// whether they hold an unread notification.
    func viewedFacts(_ store: DaemonStore) -> ViewedTabsFacts {
        ViewedTabsFacts(revision: viewedRevision,
                        tabs: viewedTabs(store).map { ViewedProgramStatus(tab: $0.id, records: $0.programStatus, unread: $0.hasUnread) })
    }

    /// The tabs shown in a key window while cmux is active: each window's
    /// focused tab, found in its own pane (O(1) per window). Only `store`'s
    /// tabs (the local daemon's).
    func viewedTabs(_ store: DaemonStore) -> [TabModel] {
        guard let services, NSApp.isActive else { return [] }
        return services.windows.controllers.compactMap { controller in
            guard controller.focus.state.windowKey, let resolved = Self.shownFocus(controller), let id = Self.contentTab(resolved),
                  let pane = resolved.pane, let model = controller.content?.paneModel(key: pane), store.pane(model.handle) === model else { return nil }
            return model.tabs.first { $0.id == id }
        }
    }
}
