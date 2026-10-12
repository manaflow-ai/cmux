import AppKit
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import Observation

extension NotificationCenterService {
    /// A `done` or `error` record that arrives while the user looks at its tab
    /// (key window, cmux active) is seen at once; focus, typing, clicks and
    /// opens see the rest through `interacted`. Pushed by observation of the
    /// viewed tabs' records, no poll. An agent chat's turns are acpmux's
    /// (`unread`, cx-n8ou): its pane says whether it shows the chat.
    func followViewedProgramStatus(_ store: DaemonStore) -> Task<Void, Never> {
        Task { [weak self] in // task-owner: start(services:) keeps the handle in tasks
            for await _ in ObservationStream({ [weak self] in self?.viewedRecords(store) ?? [] }) {
                guard let self else { return }
                for tab in self.viewedTabs(store) { ProgramStatusSeenStore.shared.markSeen(tab) }
            }
        }
    }

    /// What the seen rule follows for the viewed tabs: their OSC 7501 records.
    func viewedRecords(_ store: DaemonStore) -> [[ProgramStatusRecord]] {
        viewedTabs(store).map(\.programStatus)
    }

    /// The tabs shown in a key window while cmux is active.
    func viewedTabs(_ store: DaemonStore) -> [TabModel] {
        guard let services, NSApp.isActive else { return [] }
        return services.windows.controllers.compactMap { controller in
            guard controller.focus.state.windowKey, let id = Self.contentTab(controller.focus.state.resolved) else { return nil }
            return Self.tab(id: id, in: store)
        }
    }
}
