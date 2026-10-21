import CmuxNextActions
import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextSidebar
import Foundation
import Observation

/// The sidebar's Chief item (the `chief` built-in) and its subagent rows
/// (`SidebarTransientItem.chiefSubagents`): Leo 2026-10-20, talk to the Chief from the left side
/// next to the workspaces, see whether it works or needs you, and see its subagents under it.
/// Optional: not in the default layout; Add to Sidebar adds it. A click on the
/// item runs Open Chief (`home.openChief`: the Chief's conversation in the Home workspace's chat
/// pane); a click on a subagent row shows the tab of its chat, else opens it in a new workspace.
@Observable @MainActor
final class SidebarChiefItem {
    static let shared = SidebarChiefItem()
    private static let showsIdleKey = "sidebar.chief.showsIdleSubagents"

    /// Unfolded: the idle subagents show too. Folded (the default) still shows every working,
    /// waiting, failed or lost one. This window-independent view state stays on this Mac.
    var showsIdleSubagents = UserDefaults.standard.bool(forKey: SidebarChiefItem.showsIdleKey) {
        didSet { UserDefaults.standard.set(showsIdleSubagents, forKey: Self.showsIdleKey) }
    }

    /// The Chief item's indicator and badge (`watchStatus`): written only when they change, so the
    /// sidebar's item info is not built again for every Chief lane step.
    private(set) var status = SidebarBridge.ChiefItemStatus()
    @ObservationIgnored private var statusWatch: Task<Void, Never>?
    /// The subagent sessions a click is opening a workspace for: a second click waits for that one.
    @ObservationIgnored private var opening: Set<String> = []

    /// Follows the Chief home's lanes into `status` (idempotent; event-driven, for the app's life).
    func watchStatus(lanes: AgentLaneStore = ChatsFeed.chiefLanes) {
        guard statusWatch == nil else { return }
        // task-owner: this app-lifetime singleton; event-driven (Observation)
        statusWatch = Task { [weak self] in
            for await next in ObservationStream({ SidebarBridge.ChiefItemStatus(SidebarTransientItem.chiefStatus(lanes: lanes.lanes.values)) }) {
                guard let self else { return }
                if status != next { status = next }
            }
        }
    }

    /// The subagent rows now (they draw only under the Chief item). Read inside an observation scope
    /// (`SidebarWhatsNewItemFeed`), so a lane or fold change re-yields.
    func items(lanes: AgentLaneStore) -> [SidebarTransientItem] {
        SidebarTransientItem.chiefSubagents(lanes: lanes.lanes.values, showsIdle: showsIdleSubagents)
    }

    /// Open Chief: the item's action, also in the palette.
    static let openAction: ActionID = "home.openChief"

    /// Show Idle Chief Subagents: checked while the list is unfolded. The Chief item's right-click
    /// menu and the palette run it.
    static let toggleIdleAction: ActionID = "sidebar.chief.toggleIdleSubagents"

    static func bind(into registry: ActionRegistry, services: AppServices) {
        shared.watchStatus()
        registry.bind(openAction, invoke: { openChief(services, origin: $0.origin) })
        registry.bind(toggleIdleAction, invoke: { _ in shared.showsIdleSubagents.toggle() })
        ActionTargetTitles.setState(toggleIdleAction, in: registry) { _ in shared.showsIdleSubagents }
    }

    /// Runs a click on a subagent row; false for any other item.
    static func activate(_ id: LayoutItemID, services: AppServices) -> Bool {
        guard let session = SidebarTransientItem.chiefSubagentSession(id) else { return false }
        openSubagent(session, services: services)
        return true
    }

    /// The Chief's conversation, as Home's own conversation list opens it; Home itself before the
    /// Chief's conversation is listed.
    private static func openChief(_ services: AppServices, origin: ActionOrigin) {
        guard let chief = TopHomePageView.chief(services.home) else {
            _ = services.registry.perform("home.show", invocation: .init(origin: origin))
            return
        }
        _ = services.registry.perform("home.openConversation", invocation: .init(arguments: ["conversation": .string(chief)], origin: origin))
    }

    /// The tab that shows the subagent's chat (the workspace its spawn opened), else a new
    /// workspace on it in the Chief home's acpmux, shown once it is made.
    private static func openSubagent(_ session: String, services: AppServices) {
        guard let host = services.agentTabs.chiefHost else { return }
        if let shown = services.agentTabs.tab(showing: session, host: host), services.revealTab(shown) { return }
        guard !shared.opening.contains(session) else { return }
        let work: ActionWork
        do {
            work = try AgentSessionWorkspace.open(session: session, name: nil, cwd: nil, host: host, services: services)
        } catch {
            return services.registry.refuse(String(describing: error))
        }
        shared.opening.insert(session)
        services.registry.track(work)
        // task-owner: one open; ends with the workspace's work
        Task { @MainActor in
            defer { shared.opening.remove(session) }
            guard await work.value == nil, let tab = services.agentTabs.tab(showing: session, host: host) else { return }
            _ = services.revealTab(tab)
        }
    }
}
