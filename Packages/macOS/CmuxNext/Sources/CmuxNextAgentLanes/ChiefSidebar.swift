public import CmuxNextActions
public import CmuxNextAgentActivity
import CmuxNextApps
import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextHome
public import CmuxNextSidebar
import Foundation
public import Observation

/// The sidebar's Chief item (the `chief` built-in) and its subagent rows
/// (`SidebarTransientItem.chiefSubagents`): Leo 2026-10-20, talk to the Chief from the left side
/// next to the workspaces, see whether it works or needs you, and see its subagents under it.
/// Optional: not in the default layout; Add to Sidebar adds it. A click on the item runs Open
/// Chief (`home.openChief`: the Chief's conversation in the Home workspace's chat pane); a click
/// on a subagent row shows the tab of its chat, else opens it in a new workspace and shows it.
/// The App only hands it what it reaches through its services (`Host`).
@Observable @MainActor
public final class ChiefSidebar {
    public static let shared = ChiefSidebar()
    public static let openAction: ActionID = "home.openChief"
    /// Show Idle Chief Subagents: checked while the list is unfolded; only the Chief item's menu shows it.
    public static let toggleIdleAction: ActionID = "sidebar.chief.toggleIdleSubagents"
    /// Open Chief Subagent: its target is a subagent row's sidebar item (the Chief pane's Subagents menu).
    public static let openSubagentAction: ActionID = "chief.openSubagent"
    private static let showsIdleKey = "sidebar.chief.showsIdleSubagents"

    /// The Chief item's indicator and badge.
    public struct Status: Equatable, Sendable {
        public var activity: StatusIndicatorState = .idle
        public var badge: Int?

        public init(activity: StatusIndicatorState = .idle, badge: Int? = nil) {
            self.activity = activity
            self.badge = badge
        }
    }

    /// What the App reaches for the Chief: its conversation id (nil before it is listed), the
    /// Chief host (`chief:<id>`), the tab that shows a session there, revealing a tab, a new
    /// workspace on a session there, and whether another Chief home of this Mac keeps a session.
    public struct Host {
        public var conversation: () -> String?
        public var chiefHost: () -> String?
        public var tab: (_ session: String, _ host: String) -> String?
        public var reveal: (_ tab: String) -> Bool
        public var openWorkspace: (_ session: String, _ host: String) throws -> ActionWork
        /// Whether Chief home `host` of this Mac, not the app's own (a named Chief's), keeps
        /// `session` in its acpmux (#28877); nil: no other home's link opens.
        public var keeps: (@MainActor (_ session: String, _ host: String) async -> Bool)?

        public init(conversation: @escaping () -> String?, chiefHost: @escaping () -> String?,
                    tab: @escaping (String, String) -> String?, reveal: @escaping (String) -> Bool,
                    openWorkspace: @escaping (String, String) throws -> ActionWork,
                    keeps: (@MainActor (String, String) async -> Bool)? = nil) {
            self.conversation = conversation
            self.chiefHost = chiefHost
            self.tab = tab
            self.reveal = reveal
            self.openWorkspace = openWorkspace
            self.keeps = keeps
        }
    }

    /// Unfolded: the idle subagents show too. Folded (the default) still shows every working,
    /// waiting, failed or lost one. This view state stays on this Mac.
    public var showsIdleSubagents = UserDefaults.standard.bool(forKey: ChiefSidebar.showsIdleKey) {
        didSet { UserDefaults.standard.set(showsIdleSubagents, forKey: Self.showsIdleKey) }
    }
    /// Written only when it changes (`watch`), so a Chief lane step does not rebuild the sidebar's
    /// item info.
    public internal(set) var status = Status()
    /// Whether the sidebar shows the Chief item (`SidebarModel.followTopItems` reads the layout):
    /// the subagent fold applies only then, and the App Store's Chief in Sidebar card is on.
    public internal(set) var isPlaced = false
    @ObservationIgnored private let lanes: AgentLaneStore
    @ObservationIgnored private var host: Host?
    @ObservationIgnored private var statusWatch: Task<Void, Never>?
    /// The subagent sessions a click is opening a workspace for: a second click waits for that one.
    @ObservationIgnored private var opening: Set<String> = []

    /// `lanes`: the Chief home's lanes (its turns and subagents), which its acpmux watch writes
    /// (`ChatsFeed.startChiefTurnStates`). `host`: what the App reaches (tests pass a fake;
    /// the app sets it in ``bind(into:host:)``).
    public init(lanes: AgentLaneStore = .chief, host: Host? = nil) {
        self.lanes = lanes
        self.host = host
    }

    /// The subagent rows now (they draw only under the Chief item). Read inside an observation
    /// scope, so a lane or fold change re-yields.
    public func rows() -> [SidebarTransientItem] {
        SidebarTransientItem.chiefSubagents(lanes: lanes.lanes.values, showsIdle: showsIdleSubagents)
    }

    /// Every subagent row, idle ones too, in number order (the Chief pane's Subagents menu).
    public func allSubagents() -> [SidebarTransientItem] {
        SidebarTransientItem.chiefSubagents(lanes: lanes.lanes.values, showsIdle: true)
    }

    /// The Chief item's look with its status.
    public func decorate(_ info: inout SidebarItemInfo) {
        (info.activity, info.badge) = (status.activity, status.badge)
    }

    /// The sidebar-item menu entries a layout item does not show: Hide on a non-app item, the
    /// subagent fold on any item but the Chief, Archive on a band tile (`isTile`: Pinned, custom and app
    /// sections draw no dimmed look; plans/cmux-next/archiving-DESIGN.md).
    public static func menuRemovals(isApp: Bool, isChief: Bool, isTile: Bool = false) -> Set<ActionID> {
        var removed: Set<ActionID> = isApp ? [] : ["sidebar.item.hideApp"]
        if !isChief { removed.insert(toggleIdleAction) }
        if isTile { removed.insert("sidebar.item.toggleArchive") }
        return removed
    }

    /// Binds Open Chief, Open Chief Subagent and the fold, and starts following the lanes into `status`.
    public func bind(into registry: ActionRegistry, host: Host) {
        self.host = host
        watch()
        registry.bind(Self.openAction, invoke: { [weak self, weak registry] invocation in
            guard let registry else { return }
            self?.openChief(registry, origin: invocation.origin)
        })
        registry.bind(Self.toggleIdleAction, isEnabled: { [weak self] in self?.isPlaced == true },
                      invoke: { [weak self] _ in self?.showsIdleSubagents.toggle() })
        ActionTargetTitles.setState(Self.toggleIdleAction, in: registry) { [weak self] _ in self?.showsIdleSubagents }
        registry.bind(Self.openSubagentAction, invoke: { [weak self, weak registry] invocation in
            guard let self, let registry else { return }
            // No subagent row (its shortcut, `cmux action run` without --target): say so, never a silent no-op.
            guard let target = invocation.target else { return registry.refuse(ChiefToolStrings.noSubagent) }
            if target.kind != .sidebarItem || !activate(LayoutItemID(target.id), registry: registry) {
                registry.refuseNotFound(ChiefToolStrings.noSubagent)
            }
        })
        // The docked Home's Messages view (the Chief's chat) shows its tools in the pane's tab row.
        HomeDockSwitchView.makeRowTools = { [weak self, weak registry] mode in
            guard mode == .messages, let self, let registry else { return nil }
            return ChiefPaneTools(chief: self, registry: registry)
        }
        // The App Store's Chief in Sidebar card: Get is Add to Sidebar, Remove takes every Chief item out.
        let chief = SidebarBuiltIn.chief.rawValue
        SettingsAppFeatures.sidebarItems = .init(names: [chief], isShown: { [weak self] in $0 == chief && self?.isPlaced == true },
                                                 set: { [weak registry] name, on in Self.setPlaced(name, on, registry: registry) })
    }

    /// Runs Add to Sidebar (the top rows) or Remove Everywhere for built-in `name` as the person's edit.
    static func setPlaced(_ name: String, _ on: Bool, registry: ActionRegistry?) -> Bool {
        guard let registry else { return false }
        let invocation = on ? ActionInvocation(arguments: ["item": .string(name)], origin: .user)
            : ActionInvocation(target: ActionTargetRef(kind: .sidebarItem, id: name), origin: .user)
        return registry.perform(on ? "sidebar.item.add" : "sidebar.item.removeEverywhere", invocation: invocation)
    }

    /// Runs a click on a subagent row; false for any other item.
    public func activate(_ id: LayoutItemID, registry: ActionRegistry) -> Bool {
        guard let session = SidebarTransientItem.chiefSubagentSession(id) else { return false }
        openSubagent(session, registry: registry)
        return true
    }

    private func watch() {
        guard statusWatch == nil else { return }
        let lanes = lanes
        // task-owner: this instance (the app-lifetime `shared`); event-driven (Observation)
        statusWatch = Task { [weak self] in
            for await next in ObservationStream({ Status(SidebarTransientItem.chiefStatus(lanes: lanes.lanes.values)) }) {
                guard let self else { return }
                if status != next { status = next }
            }
        }
    }

    /// The Chief's conversation, as Home's own list opens it; Home itself before it is listed.
    private func openChief(_ registry: ActionRegistry, origin: ActionOrigin) {
        guard let chief = host?.conversation() else {
            _ = registry.perform("home.show", invocation: .init(origin: origin))
            return
        }
        _ = registry.perform("home.openConversation", invocation: .init(arguments: ["conversation": .string(chief)], origin: origin))
    }

    /// Opens a Chief subagent link (`cmux://chief/<home>/session/<session>`, the `aN` links in
    /// Home's chat). Another Chief home of this Mac (a named Chief's, #28877) opens too, once
    /// ``Host/keeps`` finds the session in its acpmux; one that does not keep it refuses. False
    /// when `chiefHost` is no Chief home this app can check, or nothing could show the session.
    ///
    /// - Parameters:
    ///   - session: The subagent's acpmux session id.
    ///   - chiefHost: The link's Chief host, `chief:<home id>`.
    ///   - registry: Where an open's work and refusal go.
    ///   - reveal: How a tab that shows the session comes forward (the link's window intent);
    ///     nil: ``Host/reveal``.
    /// - Returns: Whether the link showed or is opening something.
    public func openSubagentLink(session: String, chiefHost: String, registry: ActionRegistry,
                                 reveal: ((String) -> Bool)? = nil) -> Bool {
        guard let host, let appHost = host.chiefHost() else { return false }
        if let shown = host.tab(session, chiefHost), (reveal ?? host.reveal)(shown) { return true }
        // No tab shows it (its spawn made no workspace, as when this Mac was out of PTYs): open
        // the workspace its spawn would have, a chat tab on its session (no PTY).
        if chiefHost == appHost { return openSubagent(session, chiefHost: chiefHost, registry: registry) }
        // Another home: only a session its acpmux keeps, so a link cannot open an arbitrary id.
        guard let keeps = host.keeps else { return false }
        guard opening.insert(session).inserted else { return true }
        // task-owner: one disk check, then one open
        Task { [weak self] in
            let kept = await keeps(session, chiefHost)
            guard let self else { return }
            opening.remove(session)
            guard kept else { return registry.refuse(ChiefToolStrings.noSubagent) }
            openSubagent(session, chiefHost: chiefHost, registry: registry)
        }
        return true
    }

    /// The tab that shows the subagent's chat (the workspace its spawn opened), else a new
    /// workspace on it in the Chief home's acpmux, shown once it is made.
    /// False only when there is no Chief host (a refused open has already said why).
    @discardableResult
    private func openSubagent(_ session: String, chiefHost: String? = nil, registry: ActionRegistry) -> Bool {
        guard let host, let chiefHost = chiefHost ?? host.chiefHost() else { return false }
        if let shown = host.tab(session, chiefHost), host.reveal(shown) { return true }
        guard !opening.contains(session) else { return true }
        let work: ActionWork
        do {
            work = try host.openWorkspace(session, chiefHost)
        } catch {
            // The refusal says why; the caller adds no second ("gone") one.
            registry.refuse(String(describing: error))
            return true
        }
        opening.insert(session)
        registry.track(work)
        // task-owner: one open; ends with the workspace's work
        Task { [weak self] in
            defer { self?.opening.remove(session) }
            guard await work.value == nil, let tab = host.tab(session, chiefHost) else { return }
            _ = host.reveal(tab)
        }
        return true
    }
}

extension ChiefSidebar.Status {
    init(_ status: (activity: StatusIndicatorState, badge: Int?)) {
        self.init(activity: status.activity, badge: status.badge)
    }
}
