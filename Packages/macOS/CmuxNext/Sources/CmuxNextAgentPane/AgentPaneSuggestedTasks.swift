import CmuxNextCompat
import CmuxNextSettings
public import CmuxNextWakeups
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
    /// Follows ``isOn`` for the pages and the next daemon: a service, whose flag must change while no page shows.
    private var observation: ServiceObservation<Bool>?
    /// The app's one main-thread scheduler, from ``follow(on:)`` or the first page's model.
    private var work: MainWorkScheduler?
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

    /// The switch, read now, as a page host event; `view` then also gets every change.
    func event(for view: AgentPaneView) -> AgentPageEvent {
        follow(on: view.model.deadlines.work)
        views.add(view)
        return .suggestedTasks(isOn)
    }

    /// Pushes the switch, read now, to `view`'s page; `view` then also gets every change.
    func push(to view: AgentPaneView) {
        follow(on: view.model.deadlines.work)
        views.add(view)
        send(to: view)
    }

    /// Follows the switch on `work`, the app's one main-thread scheduler (`AppServices.mainWork`): the App calls it
    /// once it has its settings, and a page's first push does when the App has not.
    public func follow(on work: MainWorkScheduler) {
        if self.work == nil { self.work = work }
        follow()
    }

    private func send(to view: AgentPaneView) {
        view.deliver([.suggestedTasks(isOn)])
    }

    // Same shape as AgentPaneView's (cx-t7hu): not an isolated deinit.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated { observation?.cancel() }
    }

    /// Starts the observation once a scheduler is known. Its first apply, in this call, reaches only the pages
    /// pushed before (a caller adds its page after it), so no page gets the value twice.
    private func follow() {
        guard observation == nil, let work else { return }
        observation = ServiceObservation(.visible, owner: "AgentPaneSuggestedTasks.isOn", on: work) { [weak self] in
            self?.isOn ?? false
        } apply: { [weak self] on in
            guard let self else { return }  // a released instance never writes the shared flag
            Self.forNextDaemon.set(on)
            for view in views.allObjects { send(to: view) }
        }
    }
}
