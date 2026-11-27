public import CmuxNextActions
public import CmuxNextAgentActivity
import CmuxNextApps
import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextHome
public import CmuxNextHomeEngine
public import CmuxNextSidebar
import Foundation
public import Observation

/// The sidebar's Chief item (the `chief` built-in) and its subagent rows
/// (`SidebarTransientItem.chiefSubagents`): Leo 2026-10-20, talk to the Chief from the left side
/// next to the workspaces, see whether it works or needs you, and see its subagents under it.
/// The Home item is the Chief too (the person, 2026-11-20: "replace home with chief"): it draws as this item and its
/// subagents draw under it; this built-in stays for layouts that placed it. A click on either runs Open Chief
/// (`home.openChief`: the Chief's chat at the full width, or with Chief in Side Panel on, the side panel); a click
/// on a subagent row shows the tab of its chat, else opens it in a new workspace and shows it.
/// The App only hands it what it reaches through its services (`Host`).
@Observable @MainActor
public final class ChiefSidebar {
    // lint:allow singleton: the app-wide Chief item, already on base; this PR only touches the file.
    public static let shared = ChiefSidebar()
    public static let openAction: ActionID = "home.openChief"
    /// Show Idle Chief Subagents: checked while the list is unfolded; only the Chief item's menu shows it.
    public static let toggleIdleAction: ActionID = "sidebar.chief.toggleIdleSubagents"
    /// Open Chief Subagent: its target is a subagent row's sidebar item (the Chief pane's Subagents menu).
    public static let openSubagentAction: ActionID = "chief.openSubagent"
    private static let showsIdleKey = "sidebar.chief.showsIdleSubagents"

    /// The Chief item's indicator, badge and unread dot.
    public struct Status: Equatable, Sendable {
        public var activity: StatusIndicatorState = .idle
        public var badge: Int?
        /// The Chief's conversation has messages the person has not read: a dot where no badge counts.
        public var unread = false

        public init(activity: StatusIndicatorState = .idle, badge: Int? = nil, unread: Bool = false) {
            self.activity = activity
            self.badge = badge
            self.unread = unread
        }
    }

    /// What the App reaches for the Chief: its conversation id (nil before it is listed), the
    /// Chief host (`chief:<id>`), the tab that shows a session there, revealing a tab, a new
    /// workspace on a session there, whether the conversation has unread messages (read in an
    /// observation scope), and whether another Chief home of this Mac keeps a session.
    public struct Host {
        public var conversation: () -> String?
        public var unread: () -> Bool
        public var chiefHost: () -> String?
        public var tab: (_ session: String, _ host: String) -> String?
        public var reveal: (_ tab: String) -> Bool
        public var openWorkspace: (_ session: String, _ host: String) throws -> ActionWork
        /// Opens `session` of `host` as a chat tab right of tab `beside` (the link rule's column: reused, else
        /// made); false when nothing opened. Nil: a link clicked beside a tab opens as one with no tab does.
        public var openRight: ((_ session: String, _ host: String, _ beside: String) -> Bool)?
        /// Whether Chief home `host` of this Mac, not the app's own (a named Chief's), keeps
        /// `session` in its acpmux (#28877); nil: no other home's link opens.
        public var keeps: (@MainActor (_ session: String, _ host: String) async -> Bool)?
        /// Chief in Side Panel (`home.chiefDock.sidePanel`): shows the active window's docked Chief and gives it the
        /// keys, the workspace staying on the stage; false when it does not apply (off, or the window shows the Chief's
        /// page), so Open Chief opens the Chief's chat there. Nil: always the Chief's page.
        public var openSidePanel: (@MainActor () -> Bool)?

        public init(conversation: @escaping () -> String?, chiefHost: @escaping () -> String?,
                    tab: @escaping (String, String) -> String?, reveal: @escaping (String) -> Bool,
                    openWorkspace: @escaping (String, String) throws -> ActionWork,
                    openRight: ((String, String, String) -> Bool)? = nil,
                    keeps: (@MainActor (String, String) async -> Bool)? = nil,
                    openSidePanel: (@MainActor () -> Bool)? = nil, unread: @escaping () -> Bool = { false }) {
            self.conversation = conversation
            self.unread = unread
            self.chiefHost = chiefHost
            self.tab = tab
            self.reveal = reveal
            self.openWorkspace = openWorkspace
            self.openRight = openRight
            self.keeps = keeps
            self.openSidePanel = openSidePanel
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
    /// Whether the sidebar shows a row that is the Chief: the Chief item, or the Home item, which is the Chief (the
    /// person, 2026-11-20). Its subagents draw under it and its menu has the subagent fold.
    public internal(set) var showsThread = false
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

    /// The Chief item's look with its status: an unread conversation shows a dot unless a badge counts.
    public func decorate(_ info: inout SidebarItemInfo) {
        (info.activity, info.badge) = (status.activity, status.badge)
        info.unreadDot = status.unread && status.badge == nil
    }

    /// Whether Home's list dots the Chief's conversation `chief`: one of `home`'s unread conversations (unread
    /// messages or Mark as Unread, never a muted one). Read in the status observation, so a change re-yields.
    public static func isUnread(_ chief: String?, in home: HomeSidebarSource) -> Bool {
        guard let chief else { return false }
        return home.unreadConversations.contains { $0.rawValue == chief }
    }

    /// The Home item's look: it is the Chief (the person, 2026-11-20: "replace home with chief"; David Beyer: the
    /// Chief is a thread like the others). The Chief's name and glyph, its `picture` (nil keeps the glyph), its status
    /// and the subagents that need the person, and the blue unread dot of a workspace row while any of the person's
    /// `homeUnread` chats is unread, never a count (Lawrence 2026-10-23: "home unread indicator should just be blue dot").
    public func decorateHome(_ info: inout SidebarItemInfo, homeUnread: Int, picture: SidebarFavicon?) {
        // The Chief's look (sparkles, the Chief's picture) under the top row's own name, "Chief": the Chief Activity
        // item keeps its own title (cmux#48416).
        let chief = SidebarBuiltIn.chief.defaultInfo
        (info.title, info.symbol, info.icon, info.favicon) = (SidebarBuiltIn.home.title, chief.symbol, chief.icon, picture)
        // The row draws the title alone, so it reads as the top of the list, not as one more glyph row (Lucas 2026-11-23).
        info.hidesGlyphBesideTitle = true
        decorate(&info)
        // The top row dots for any of the person's unread chats (the Chief's own among them), not only the Chief's.
        info.unreadDot = homeUnread > 0
    }

    /// Whether a click on an item with `ref` opens the Chief's chat (``openAction``): the Home item, app or built-in,
    /// which is the Chief, so it opens on the Chief even when another chat was open there last.
    public static func opensChief(_ ref: LayoutItemRef) -> Bool { ref == SidebarLayoutDocument.homeRef || ref == .builtIn(.home) }

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
        follow(host)
        registry.bind(Self.openAction, invoke: { [weak self, weak registry] invocation in
            guard let registry else { return }
            self?.openChief(registry, origin: invocation.origin)
        })
        registry.bind(Self.toggleIdleAction, isEnabled: { [weak self] in self?.showsThread == true },
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

    /// Reaches the App through `host` and follows the lanes and the conversation's unread state into `status`.
    func follow(_ host: Host) {
        self.host = host
        watch()
    }

    private func watch() {
        guard statusWatch == nil else { return }
        let lanes = lanes
        let unread = host?.unread ?? { false }
        // task-owner: this instance (the app-lifetime `shared`); event-driven (Observation)
        statusWatch = Task { [weak self] in
            for await next in ObservationStream({ Status(SidebarTransientItem.chiefStatus(lanes: lanes.lanes.values), unread: unread()) }) {
                guard let self else { return }
                if status != next { status = next }
            }
        }
    }

    /// The Chief's conversation, as Home's own list opens it; Home itself before it is listed. With Chief in Side
    /// Panel on, the side panel beside the shown workspace instead (``Host/openSidePanel``).
    private func openChief(_ registry: ActionRegistry, origin: ActionOrigin) {
        if host?.openSidePanel?() == true { return }
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
    ///   - besideTab: The tab the link was clicked in (Home's, a subagent pill or `aN` link): with no tab showing
    ///     the session, its chat opens as a real tab on that tab's right (``Host/openRight``; user 2026-11-04,
    ///     msg 21663: "just open it as pane to right side"), never a new workspace. Nil: as the sidebar row opens it.
    ///   - reveal: How a tab that shows the session comes forward (the link's window intent);
    ///     nil: ``Host/reveal``.
    /// - Returns: Whether the link showed or is opening something.
    public func openSubagentLink(session: String, chiefHost: String, registry: ActionRegistry, besideTab: String? = nil,
                                 reveal: ((String) -> Bool)? = nil) -> Bool {
        guard let host, let appHost = host.chiefHost() else { return false }
        if let shown = host.tab(session, chiefHost), (reveal ?? host.reveal)(shown) { return true }
        if chiefHost == appHost, let besideTab, let openRight = host.openRight, openRight(session, chiefHost, besideTab) { return true }
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
    /// workspace on it in the Chief home's acpmux, shown once the app lists it (in this turn when
    /// the app shows it before the daemon's creates).
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
        // The app shows the new workspace and its chat tab in this turn when it can (P4): that tab comes
        // forward now, and the work's end brings nothing forward again.
        let shownNow = host.tab(session, chiefHost).map(host.reveal) ?? false
        // task-owner: one open; ends with the workspace's work
        Task { [weak self] in
            defer { self?.opening.remove(session) }
            guard await work.value == nil, !shownNow, let tab = host.tab(session, chiefHost) else { return }
            _ = host.reveal(tab)
        }
        return true
    }
}

extension ChiefSidebar.Status {
    init(_ status: (activity: StatusIndicatorState, badge: Int?), unread: Bool = false) {
        self.init(activity: status.activity, badge: status.badge, unread: unread)
    }
}
