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
    ///   when the dismissal policy reads on focus (`interacted(.focus)`, the
    ///   default; `click` keeps it until the pane is clicked or typed in).
    /// Focus, typing, clicks and opens see the rest through `interacted`. An
    /// agent chat's turns are acpmux's (`unread`, cx-n8ou): its pane says
    /// whether it shows the chat.
    func followViewedProgramStatus(_ store: DaemonStore) -> Task<Void, Never> {
        Task { [weak self] in // task-owner: start(services:) keeps the handle in tasks
            for await _ in ObservationStream({ [weak self] in self?.viewedFacts(store) ?? ViewedTabsFacts(revision: 0, tabs: []) }) {
                guard let self else { return }
                // A tab a strip press is moving is focused, not looked at (`viewHolds`).
                let all = self.viewedTabs(store)
                let viewed = self.unheld(all)
                for tab in viewed { self.interacted(.focus, tab: tab) }
                self.clearTabMarks(entering: viewed, held: Set(all.map(\.id)).subtracting(viewed.map(\.id)))
            }
        }
    }

    /// Clears the manual mark (Mark Tab Unread, `TabUnreadMark`) of each tab
    /// that came into view since the last pass. A tab marked while viewed
    /// keeps the mark until it is viewed again. A `held` tab counts as in view
    /// all along: its move brought it no look, so it keeps its mark.
    func clearTabMarks(entering viewed: [TabModel], held: Set<String> = []) {
        let entered = Set(TabUnreadMark.entered(viewed.map(\.id), previous: viewedTabIDs.union(held)))
        viewedTabIDs = Set(viewed.map(\.id)).union(held)
        for tab in viewed where tab.markedUnread && entered.contains(tab.id) {
            guard let daemon = owner(of: tab) else { continue }
            try? TabUnreadMark.set(false, tab: tab, daemon: daemon)
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
    /// focused tab, found in its own pane (O(1) per window), in the window's own
    /// daemon store (any machine; `store` is unused).
    func viewedTabs(_ store: DaemonStore) -> [TabModel] {
        guard let services, services.appActiveSource() else { return [] }
        return services.windows.controllers.compactMap { controller in
            guard controller.focus.state.windowKey, let resolved = Self.shownFocus(controller), let id = Self.contentTab(resolved),
                  let pane = resolved.pane, let content = controller.content, let model = content.paneModel(key: pane),
                  content.daemon.store.pane(model.handle) === model else { return nil }
            return model.tabs.first { $0.id == id }
        }
    }
}
