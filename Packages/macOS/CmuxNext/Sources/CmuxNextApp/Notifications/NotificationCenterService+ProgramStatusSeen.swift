import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import Observation

extension NotificationCenterService {
    /// A `done` or `error` record that arrives while the user looks at its
    /// terminal (key window, cmux active) is seen at once; focus, typing,
    /// clicks and opens see the rest through `interacted`. Pushed by
    /// observation of the viewed tabs' records, no poll.
    func followViewedProgramStatus(_ store: DaemonStore) -> Task<Void, Never> {
        Task { [weak self] in // task-owner: start(services:) keeps the handle in tasks
            for await _ in Observations({ [weak self] in self?.viewedTabs(store).map(\.programStatus) ?? [] }) {
                guard let self else { return }
                for tab in self.viewedTabs(store) { ProgramStatusSeenStore.shared.markSeen(tab) }
            }
        }
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
