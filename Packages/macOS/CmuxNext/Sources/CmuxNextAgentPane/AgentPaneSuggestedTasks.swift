import CmuxNextCompat
import CmuxNextSettings
import Foundation

/// Suggested tasks and nested child chats (cx-lo9yf) on the agent pages: whether agents suggest
/// tasks is the cmux.json switch `sessions.promptSuggestions` (``setting``, set by the App); the
/// Debug Settings toggle `agent.suggestedTasks` (``AgentPaneTunables/suggestedTasks``, off by
/// default) only forces them on. Each page
/// gets it at load and handshake (``push(to:)``), and again on every change. Not an AgentPaneView
/// extension: that type is at its size limit.
public final class AgentPaneSuggestedTasks {
    public static let shared = AgentPaneSuggestedTasks()
    /// The pages pushed so far, held weakly, for the pushes on a change.
    private let views = NSHashTable<AgentPaneView>.weakObjects()
    private var observation: Task<Void, Never>?
    /// `sessions.promptSuggestions`, read through Observation (the App reads its settings snapshot).
    public var setting: @MainActor () -> Bool = { SessionSettings.promptSuggestionsDefault } {
        // Written now, not only by the observation: a daemon started before its first pass
        // (AgentTabs prewarms one at launch) still gets the tools.
        didSet { Self.forNextDaemon.set(isOn); observation?.cancel(); observation = nil; follow() }
    }
    /// The value for the next acpmux daemon this app starts (``AcpmuxHost``, off the main actor),
    /// kept current here on the main actor.
    public nonisolated static let forNextDaemon = Flag(SessionSettings.promptSuggestionsDefault)

    /// A Bool read from any thread.
    public nonisolated final class Flag: Sendable {
        private let value: Mutex<Bool>
        init(_ on: Bool) { value = Mutex(on) }
        public var isOn: Bool { value.withLock { $0 } }
        func set(_ on: Bool) { value.withLock { $0 = on } }
    }

    /// Whether agents suggest tasks now: the setting decides; the Debug Settings toggle, off by
    /// default, only forces them on.
    var isOn: Bool { setting() || AgentPaneTunables.suggestedTasks.value }

    /// The script that tells a loaded page whether agents suggest tasks.
    static func script(_ on: Bool) -> String {
        "window.cmuxAcpmuxBridge?.applySuggestedTasks?.(\(on));"
    }

    /// The switch, read now, as a page host event; `view` then also gets every change.
    func event(for view: AgentPaneView) -> AgentPageEvent {
        views.add(view)
        follow()
        return .suggestedTasks(isOn)
    }

    /// Pushes the switch, read now, to `view`'s page; `view` then also gets every change.
    func push(to view: AgentPaneView) {
        views.add(view)
        follow()
        send(to: view)
    }

    private func send(to view: AgentPaneView) {
        let on = isOn
        view.deliver([.suggestedTasks(on)], scripts: [Self.script(on)])
    }

    // Same shape as AgentPaneView's (cx-t7hu): not an isolated deinit.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    private func follow() {
        guard observation == nil else { return }
        // task-owner: app-lifetime; event-driven (Observation on the setting and the tunable key)
        observation = Task { [weak self] in
            for await on in ObservationStream({ [weak self] in self?.isOn ?? false }) {
                guard let self else { return }  // a released instance never writes the shared flag
                Self.forNextDaemon.set(on)
                for view in views.allObjects { send(to: view) }
            }
        }
    }
}
