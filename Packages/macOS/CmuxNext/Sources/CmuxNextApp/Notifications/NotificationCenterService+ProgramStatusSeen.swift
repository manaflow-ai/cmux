import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import Observation

extension NotificationCenterService {
    /// A `done` or `error` record, or an agent chat turn that completes, while
    /// the user looks at its tab (key window, cmux active) is seen at once; focus, typing,
    /// clicks and opens see the rest through `interacted`. Pushed by
    /// observation of the viewed tabs' records, no poll.
    func followViewedProgramStatus(_ store: DaemonStore) -> Task<Void, Never> {
        Task { [weak self] in // task-owner: start(services:) keeps the handle in tasks
            for await _ in Observations({ [weak self] in self?.viewedFacts(store) ?? [] }) {
                guard let self else { return }
                for tab in self.viewedTabs(store) { ProgramStatusSeenStore.shared.markSeen(tab, turns: .shared) }
            }
        }
    }

    /// What the seen rule follows for the viewed tabs: their OSC 7501 records
    /// and their agent chat turn states.
    func viewedFacts(_ store: DaemonStore) -> [ViewedFacts] {
        viewedTabs(store).map { tab in
            ViewedFacts(records: tab.programStatus, turn: tab.agentSession.flatMap(AgentTurnStateStore.shared.state(for:)))
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

/// One viewed tab's facts for `followViewedProgramStatus` (an observed value).
struct ViewedFacts: Equatable, Sendable {
    var records: [ProgramStatusRecord]
    var turn: AgentTurnState?
}
