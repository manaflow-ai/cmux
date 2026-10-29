import Foundation
public import Observation

/// The daemon's state resources (closed history, workspace status, ephemeral
/// workspaces, screen metadata and groups, tab records, terminal progress)
/// mirrored from `session.events` for one connection. The raw tree carries
/// none of these fields, so this mirror is their only source: the record
/// fields it lays over workspaces, screens and tabs are projections of
/// `mirror`, rebuilt after each structural change and each state change,
/// never written by the app (state-ownership.md 1). `DaemonStore.session`.
@MainActor @Observable
public final class SessionStateStore {
    /// Nil while the daemon serves none (it predates them, or the stream has
    /// not delivered its snapshot). Not observed: a status tick changes it
    /// several hundred times a second, and each change is laid over only
    /// the records it touched; readers observe those records, or
    /// `closedItems`.
    @ObservationIgnored public private(set) var mirror: SessionStateMirror?
    /// True once this connection's daemon answered whether it serves state
    /// resources (a snapshot, or a stream it refused); reset on connect.
    public internal(set) var known = false
    /// Recently closed tabs, screens, and workspaces, newest first. Its own
    /// stored value: written only when the closed list changed, so its
    /// observers do not run on every status tick.
    public private(set) var closedItems: [ClosedItem] = []
    /// Bumped with each change of ``closedItems``: an observer of several machines' closed
    /// lists reads one number per machine, never the lists.
    public private(set) var closedRevision: UInt64 = 0
    /// Counts stash changes (`stash-v1`) on this connection, and each fresh
    /// snapshot (changes in the gap were lost). Its readers (the Stashed
    /// page) list the stashes again when it moves; the mirror keeps none.
    public private(set) var stashChanges = 0

    /// Sidebar document batches (`sidebar-doc-v1`), in stream order; the
    /// sidebar's document store applies them to its mirror.
    @ObservationIgnored public var onSidebarBatch: (@MainActor (SidebarDocBatch) -> Void)?
    /// A fresh stream snapshot: the sidebar document refetches (`sidebar.get`),
    /// since batches during the gap were lost.
    @ObservationIgnored public var onSidebarResync: (@MainActor () -> Void)?

    public init() {}

    /// A new connection: known at once when its daemon serves no state
    /// resources, else once the stream's snapshot (or its end) arrives.
    func connected(servesStateResources: Bool) {
        known = !servesStateResources
    }

    /// Applies one `session.events` item to the mirror and lays what it
    /// changed over `store`'s records: a snapshot over every record, a delta
    /// over the records it touched (found by resource id in O(1)).
    func apply(_ item: SessionStreamItem, in store: DaemonStore) {
        switch item {
        case .snapshot(let snapshot):
            if mirror != snapshot { mirror = snapshot }
            if !known { known = true }
            publishClosed()
            stashChanges &+= 1
            onSidebarResync?()
            overlay(store.workspaces)
        case .delta(let changes):
            var touched: Set<SessionStateMirror.Touched> = []
            for change in changes {
                if case .sidebarBatch(let batch) = change {
                    onSidebarBatch?(batch)
                } else if mirror != nil {
                    mirror?.apply(change, touched: &touched)
                }
            }
            for record in touched { lay(record, in: store) }
        case .ended:
            // The reopened stream's snapshot replaces the mirror; a stream
            // that could not open leaves no snapshot to wait for.
            if !known { known = true }
        }
    }

    private func publishClosed() {
        let closed = mirror?.closed ?? []
        guard closedItems != closed else { return }
        closedItems = closed
        closedRevision &+= 1
    }

    /// Lays the mirror over the one record `touched` names.
    private func lay(_ touched: SessionStateMirror.Touched, in store: DaemonStore) {
        switch touched {
        case .workspace(let id):
            if let workspace = store.index.workspacesByResource[id] { lay(workspaceOnly: workspace) }
        case .screen(let id):
            guard let screen = store.index.screensByResource[id] else { return }
            screen.applyState(mirror?.screens[id] ?? SessionStateMirror.ScreenState())
        case .tab(let id):
            if let tab = store.index.tabsByResource[id] { Self.lay(mirror, over: tab) }
        case .terminal(let id):
            if let tab = store.index.tabsByTerminalResource[id] { Self.lay(mirror, over: tab) }
        case .closed:
            publishClosed()
        case .stash:
            stashChanges &+= 1
        }
    }

    /// Lays `mirror` over every workspace, screen, and tab record of
    /// `workspaces`. Without state resources the records keep the raw
    /// tree's values.
    func overlay(_ workspaces: [WorkspaceModel]) {
        for workspace in workspaces {
            for screen in workspace.screens { lay(screen: screen) }
            lay(workspaceOnly: workspace)
        }
    }

    /// Lays `mirror` over `screen` and its tabs.
    func lay(screen: ScreenModel) {
        if let state = mirror, let id = screen.resourceID {
            screen.applyState(state.screens[id] ?? SessionStateMirror.ScreenState())
        }
        for pane in screen.panes {
            for tab in pane.tabs { Self.lay(mirror, over: tab) }
        }
    }

    /// Lays `mirror` over the workspace's own fields (ephemeral, agent
    /// folder, status, screen groups), not its screens.
    func lay(workspaceOnly workspace: WorkspaceModel) {
        let state = mirror
        let id = workspace.resourceID
        let groups = state.flatMap { state in id.map { Self.screenGroups(state, workspace: $0, screens: workspace.screens) } }
        workspace.applyState(ephemeral: id.map { state?.ephemeralWorkspaces.contains($0) ?? false } ?? false,
                             agentFolder: id.flatMap { state?.agentFolders[$0] },
                             notes: id.flatMap { state?.workspaceNotes[$0] } ?? .init(),
                             status: id.flatMap { state?.workspaceStatus[$0] },
                             checklist: id.flatMap { state?.workspaceChecklists[$0]?.items } ?? [], screenGroups: groups)
    }

    /// Lays `state`'s tab record and terminal records over `tab` (`overlay`'s tab step).
    static func lay(_ state: SessionStateMirror?, over tab: TabModel) {
        tab.applyState(tab.resourceID.flatMap { state?.tabs[$0] },
                       progress: tab.terminalResourceID.flatMap { state?.terminalProgress[$0] },
                       programStatus: tab.terminalResourceID.flatMap { state?.terminalProgramStatus[$0] } ?? [],
                       commandSinceMs: tab.terminalResourceID.flatMap { state?.terminalBusySinceMs[$0] },
                       promptSinceMs: tab.terminalResourceID.flatMap { state?.terminalPromptSinceMs[$0] },
                       lastOutputMs: tab.terminalResourceID.flatMap { state?.terminalLastOutputMs[$0] },
                       shellIdleSinceMs: tab.terminalResourceID.flatMap { state?.terminalShellIdleSinceMs[$0] })
    }

    /// The app's screen group runs for `workspace`, in screen order.
    static func screenGroups(_ state: SessionStateMirror, workspace: ResourceID, screens: [ScreenModel]) -> [ScreenGroupSnapshot] {
        let order = screens.compactMap(\.resourceID)
        let handles = Dictionary(screens.compactMap { screen in screen.resourceID.map { ($0, screen.handle) } },
                                 uniquingKeysWith: { first, _ in first })
        return state.screenGroups(of: workspace, screenOrder: order).map { group in
            let members = group.screenIDs.compactMap { handles[$0] }
            let start = group.screenIDs.compactMap { order.firstIndex(of: $0) }.min() ?? 0
            return ScreenGroupSnapshot(id: ScreenGroupID(rawValue: group.id), name: group.name, color: group.color,
                                       collapsed: group.collapsed, savedID: group.savedID.map(SavedScreenGroupID.init(rawValue:)),
                                       start: start, screens: members, icon: group.icon)
        }
    }
}
