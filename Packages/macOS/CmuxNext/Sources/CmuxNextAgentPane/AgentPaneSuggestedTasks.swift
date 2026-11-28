import CmuxNextCompat
import Foundation

/// Suggested tasks and nested child chats (cx-lo9yf) on the agent pages: whether agents suggest
/// tasks, the Debug Settings toggle `agent.suggestedTasks` (``AgentPaneTunables/suggestedTasks``).
/// Each page gets it at load and handshake (``push(to:)``), and again on every change of the
/// toggle. Not an AgentPaneView extension: that type is at its size limit.
final class AgentPaneSuggestedTasks {
    static let shared = AgentPaneSuggestedTasks()
    /// The pages pushed so far, held weakly, for the pushes on a change.
    private let views = NSHashTable<AgentPaneView>.weakObjects()
    private var observation: Task<Void, Never>?

    /// The script that tells a loaded page whether agents suggest tasks.
    static func script(_ on: Bool) -> String {
        "window.cmuxAcpmuxBridge?.applySuggestedTasks?.(\(on));"
    }

    /// The toggle, read now, as a page host event; `view` then also gets every change.
    func event(for view: AgentPaneView) -> AgentPageEvent {
        follow(view)
        return .suggestedTasks(AgentPaneTunables.suggestedTasks.value)
    }

    /// Pushes the toggle, read now, to `view`'s page; `view` then also gets every change.
    func push(to view: AgentPaneView) {
        follow(view)
        Self.send(to: view)
    }

    private static func send(to view: AgentPaneView) {
        let on = AgentPaneTunables.suggestedTasks.value
        view.deliver([.suggestedTasks(on)], scripts: [script(on)])
    }

    private func follow(_ view: AgentPaneView) {
        views.add(view)
        guard observation == nil else { return }
        // task-owner: app-lifetime; event-driven (Observation on the one tunable key)
        observation = Task { [weak self] in
            for await _ in ObservationStream({ AgentPaneTunables.suggestedTasks.value }) {
                guard let self else { return }
                for view in views.allObjects { Self.send(to: view) }
            }
        }
    }
}
