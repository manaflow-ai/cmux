import Foundation
import Observation

/// The daemon's state resources (`session.events`) laid over the tree
/// records. The raw tree carries none of these fields, so the mirror is
/// their only source: every record field below is a projection of
/// `sessionState`, rebuilt after each structural change and each state
/// change, never written by the app (state-ownership.md 1).
extension DaemonStore {
    /// True once this daemon delivered state resources: closed history,
    /// ephemeral workspaces, workspace status, the v2 state mutations
    /// (`DaemonCapabilities.stateResources`).
    public var servesStateResources: Bool { sessionState != nil }

    /// Whether this daemon serves `capability`: its `identify`, or the
    /// state resources for the capabilities they provide.
    public func supports(_ capability: String) -> Bool {
        if DaemonCapabilities.providedByStateResources.contains(capability), servesStateResources { return true }
        return identity?.supports(capability) ?? false
    }

    /// Recently closed tabs, screens, and workspaces, newest first.
    public var closedItems: [ClosedItem] { sessionState?.closed ?? [] }

    /// The workspace whose public id is `id`.
    public func workspace(resourceID id: ResourceID) -> WorkspaceModel? {
        workspaces.first { $0.resourceID == id }
    }

    /// Returns once the tree reflects every event up to `sequence` (a
    /// `DaemonConnection.eventSequence()` taken after a command's reply), or
    /// the connection changed. Event-driven: it observes the store.
    public func applied(through sequence: UInt64?) async {
        guard let sequence, appliedSequence < sequence else { return }
        let state = connectionState
        for await done in Observations({ self.appliedSequence >= sequence || self.connectionState != state }) where done {
            return
        }
    }

    /// Returns once this daemon answered whether it serves state resources
    /// (`sessionStateKnown`), or the connection changed.
    public func sessionStateResolved() async {
        guard !sessionStateKnown else { return }
        let state = connectionState
        for await done in Observations({ self.sessionStateKnown || self.connectionState != state }) where done {
            return
        }
    }

    /// Applies one `session.events` item.
    func applySessionState(_ item: SessionStreamItem) {
        switch item {
        case .snapshot(let mirror):
            if sessionState != mirror { sessionState = mirror }
            if !sessionStateKnown { sessionStateKnown = true }
        case .unsupported:
            if sessionState != nil { sessionState = nil }
            if !sessionStateKnown { sessionStateKnown = true }
        case .delta(let changes):
            guard var state = sessionState else { return }
            state.apply(changes)
            if state != sessionState { sessionState = state }
        case .ended:
            // The reopened stream's snapshot replaces the mirror.
            return
        }
        applyStateOverlay()
    }

    /// Lays `sessionState` over every workspace, screen, and tab record.
    /// Without state resources the records keep the raw tree's values.
    func applyStateOverlay() {
        let state = sessionState
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
                                 status: id.flatMap { state?.workspaceStatus[$0] }, screenGroups: groups)
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs {
                        tab.applyState(tab.resourceID.flatMap { state?.tabs[$0] },
                                       progress: tab.terminalResourceID.flatMap { state?.terminalProgress[$0] })
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
                                       collapsed: group.collapsed, start: start, screens: members)
        }
    }
}
