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
    /// not delivered its snapshot).
    public internal(set) var mirror: SessionStateMirror?
    /// True once this connection's daemon answered whether it serves state
    /// resources (a snapshot, or a stream it refused); reset on connect.
    public internal(set) var known = false

    public init() {}

    /// Recently closed tabs, screens, and workspaces, newest first.
    public var closedItems: [ClosedItem] { mirror?.closed ?? [] }

    /// A new connection: known at once when its daemon serves no state
    /// resources, else once the stream's snapshot (or its end) arrives.
    func connected(servesStateResources: Bool) {
        known = !servesStateResources
    }

    /// Applies one `session.events` item and lays the mirror over
    /// `workspaces` when it changed what the records show.
    func apply(_ item: SessionStreamItem, to workspaces: [WorkspaceModel]) {
        switch item {
        case .snapshot(let snapshot):
            if mirror != snapshot { mirror = snapshot }
            if !known { known = true }
        case .delta(let changes):
            guard var state = mirror else { return }
            state.apply(changes)
            if state != mirror { mirror = state }
        case .ended:
            // The reopened stream's snapshot replaces the mirror; a stream
            // that could not open leaves no snapshot to wait for.
            if !known { known = true }
            return
        }
        overlay(workspaces)
    }

    /// Lays `mirror` over every workspace, screen, and tab record. Without
    /// state resources the records keep the raw tree's values.
    func overlay(_ workspaces: [WorkspaceModel]) {
        let state = mirror
        for workspace in workspaces {
            let id = workspace.resourceID
            var groups: [ScreenGroupSnapshot]?
            if let state, let id {
                for screen in workspace.screens {
                    guard let screenID = screen.resourceID else { continue }
                    screen.applyState(state.screens[screenID] ?? SessionStateMirror.ScreenState())
                }
                groups = Self.screenGroups(state, workspace: id, screens: workspace.screens)
            }
            workspace.applyState(ephemeral: id.map { state?.ephemeralWorkspaces.contains($0) ?? false } ?? false,
                                 agentFolder: id.flatMap { state?.agentFolders[$0] },
                                 status: id.flatMap { state?.workspaceStatus[$0] }, screenGroups: groups)
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs {
                        tab.applyState(tab.resourceID.flatMap { state?.tabs[$0] },
                                       progress: tab.terminalResourceID.flatMap { state?.terminalProgress[$0] },
                                       programStatus: tab.terminalResourceID.flatMap { state?.terminalProgramStatus[$0] } ?? [])
                    }
                }
            }
        }
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
                                       start: start, screens: members)
        }
    }
}
