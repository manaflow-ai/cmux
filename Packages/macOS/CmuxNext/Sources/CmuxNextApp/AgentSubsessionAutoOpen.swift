import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat

/// A sub-session an agent chat's agent starts opens as a tab beside that chat, without taking
/// focus (`agent.subsessionAutoOpen`, on by default): through the shared ``AgentSessionTabOpener``,
/// so it lands in the chat's side pane, else a split right of it, and a tab that shows it already
/// is kept. Only sub-sessions that appear while the app watches open: the ones acpmux lists in its
/// first page were there before, and stay in the sidebar until someone opens one. A sub-session
/// whose parent chat has no tab open here is left in the sidebar too.
final class AgentSubsessionAutoOpen {
    private let tabs: AgentTabStore
    /// Every sub-session seen so far; nil until the watch's first page.
    private var seen: Set<String>?
    private var watch: Task<Void, Never>?

    init(tabs: AgentTabStore) {
        self.tabs = tabs
    }

    /// The app's one follower, started with the turn-state watch (`ChatsFeed.started`).
    private static var shared: AgentSubsessionAutoOpen?

    /// Starts the app's follower of acpmux's sub-session tree; once.
    static func start(tabs: AgentTabStore) {
        guard shared == nil else { return }
        let follower = AgentSubsessionAutoOpen(tabs: tabs)
        shared = follower
        follower.start()
    }

    /// Starts following acpmux's sub-session tree; once.
    func start() {
        guard watch == nil else { return }
        let store = AgentTurnStateStore.shared
        // task-owner: the app's one follower of the sub-session tree; it ends with this object.
        watch = Task { [weak self] in
            for await parents in ObservationStream({ store.watching ? store.openSubsessionParents() : nil }) {
                guard let self else { return }
                self.saw(parents)
            }
        }
    }

    /// The tree's open sub-sessions by id with their parent, nil while the watch is down.
    func saw(_ parents: [String: String]?) {
        guard let parents else { return }
        guard let known = seen else {
            seen = Set(parents.keys)
            return
        }
        let new = parents.filter { !known.contains($0.key) }.sorted { $0.key < $1.key }
        seen = known.union(new.map(\.key))
        guard AgentPaneTunables.subsessionAutoOpen.value else { return }
        for (session, parent) in new where tabs.tab(showing: session) == nil {
            guard let anchor = tabs.tab(showing: parent) else { continue }
            AgentSessionTabOpener(tabs: tabs).open(session, beside: anchor, focus: false)
        }
    }
}
