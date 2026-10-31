import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import Foundation
import Observation

// Which profile each window shows (plans/cmux-next/data-model.md 4). The
// profile is the window's own state (`WindowState.profileID`, persisted in
// the personal projection); membership stays `WindowRegistry`'s. A switch
// changes only what the window lists and shows, in one main-actor turn:
// terminals keep running in the daemon and hidden surfaces take the normal
// hidden-tab path, so nothing restarts or flashes.
extension WindowManager {
    /// Shows `profile` in `state`'s window: the workspaces the window holds
    /// in it (the last one shown there is selected), else the profile's
    /// workspaces no open window showing that profile holds, else a new
    /// workspace created in it.
    func switchProfile(_ profile: ProfileID, in state: WindowState) {
        guard profile != state.profileID else { return }
        // An incognito space lives in its incognito window (spaces-overhaul-DESIGN.md rule 2): switching another
        // window to it shows that window instead, and an incognito space's window never shows a normal space.
        if incognitoSpaces[state.id] != nil { return services.registry.refuse(RefusalStrings.incognitoMismatch) }
        if let owner = incognitoSpaces.first(where: { $0.value == profile })?.key {
            if ActionRunScope.viewChangeAllowed(), let controller = controller(for: owner) { bringToFront(controller) }
            return
        }
        let machines = services.machines
        let members = registry.members(of: state.id)
        var visible = WindowProfiles.visible(members, profile: profile, machines: machines)
        if visible.isEmpty {
            let adoptable = adoptableWorkspaces(in: profile, for: state.id)
            if !adoptable.isEmpty {
                transition { $0.move(adoptable, to: state.id) }
                visible = adoptable
            }
        }
        guard !visible.isEmpty else {
            // Nothing to show there yet: the window enters the profile with
            // a new workspace (no empty window, REWRITE.md round 1). It is
            // claimed before the create command, so the switch shows it as
            // soon as the daemon mirrors it.
            state.enterProfile(profile)
            recordSaver.stateDidChange(state)
            Task { [services] in await createWorkspace(into: state.id); withExtendedLifetime(services) {} }
            return
        }
        let remembered = state.profileWorkspaces[profile].flatMap { visible.contains($0) ? $0 : nil }
        state.enterProfile(profile)
        select(remembered ?? visible.first, in: state)
    }

    /// Next (+1) or previous (-1) profile of the local daemon, clamped at
    /// the ends. Returns false when there is none that way.
    @discardableResult
    func stepProfile(by delta: Int, in state: WindowState) -> Bool {
        let order = services.machines.local.store.profileIDs
        guard let index = order.firstIndex(of: state.profileID) ?? order.indices.first else { return false }
        let target = min(max(index + delta, 0), order.count - 1)
        guard target != index else { return false }
        switchProfile(order[target], in: state)
        return true
    }

    /// Workspaces of `profile` on every session that no open window
    /// currently showing `profile` holds (hidden in other windows, in the
    /// closed window, or not placed yet), in daemon order.
    func adoptableWorkspaces(in profile: ProfileID, for windowID: String) -> [String] {
        let value = registry.value
        let shownElsewhere = Set(value.openWindows.filter { window in
            window.id != windowID && states[window.id]?.profileID == profile
        }.flatMap(\.workspaceIDs))
        let machines = services.machines
        return machines.daemons.flatMap { WindowProfiles.workspaces(of: $0, in: profile, machines: machines) }
            .map(\.id).filter { !shownElsewhere.contains($0) }
    }

    /// Selecting a workspace of another room (palette, CLI, a
    /// notification) shows that room in the window first.
    func enterProfile(of workspaceID: String, in state: WindowState) {
        guard let room = WindowProfiles.room(of: workspaceID, current: state.profileID, machines: services.machines) else { return }
        state.enterProfile(room)
    }
}

extension DaemonStore {
    /// Returns once this store holds room `id`, or the connection changed.
    /// A command's reply comes before the mirror: rooms arrive through
    /// `personal-changed` and a resync. Event-driven: it observes the store.
    func mirrored(profile id: ProfileID) async {
        guard profile(id) == nil else { return }
        let state = connectionState
        for await done in ObservationStream({ self.profile(id) != nil || self.connectionState != state }) where done {
            return
        }
    }
}

// Folding windows together (Leo 2026-10-29: "having windows be switchable in this way"): one registry transition each;
// workspaces change owner and keep running, an emptied window closes. Incognito never moves (spaces-overhaul rule 2).
extension WindowManager {
    /// Move Space to This Window: `profile`'s workspaces in other normal windows move here, and this window shows `profile`
    /// at its last shown workspace (none elsewhere: a plain switch; no view-change permission: the view stays).
    func bringSpace(_ profile: ProfileID, into state: WindowState) throws {
        let value = registry.value
        if value.isIncognito(state.id) || incognitoSpaces[state.id] != nil || incognitoSpaces.values.contains(profile) {
            throw ActionFailure.invalidTarget(RefusalStrings.incognitoMismatch)
        }
        let machines = services.machines
        let sources = value.windows.filter { $0.id != state.id && !value.isIncognito($0.id) }
        // Only workspaces whose space is known move (one no session reports yet shows in every space); window Homes stay.
        let moving = sources.flatMap { WindowProfiles.visible($0.workspaceIDs, profile: profile, machines: machines) }
            .filter { WindowProfiles.qualified($0, machines: machines) != nil && !isWindowHome($0) }
        try refuseClosingCreating(sources.filter { !$0.workspaceIDs.isEmpty && Set(moving).isSuperset(of: $0.workspaceIDs) }.map(\.id))
        // A CLI or MCP run without focus permission leaves this window's view alone (as `RoomHandlers.startNewSpace`).
        let mayShow = ActionRunScope.viewChangeAllowed()
        guard !moving.isEmpty else {
            if mayShow { switchProfile(profile, in: state) }
            return
        }
        // A window already on the space keeps its selection; else the space's last shown workspace.
        var preferred: [String: [String]] = [:]
        if state.profileID != profile, mayShow {
            let candidates = Set(moving + WindowProfiles.visible(value.window(state.id)?.workspaceIDs ?? [], profile: profile, machines: machines))
            preferred[state.id] = lastShown(in: profile, recency: value.recency, here: state).filter(candidates.contains)
            state.enterProfile(profile)
        }
        carryLocalBrowserTabs(of: moving, from: sources, to: state)
        transition(select: preferred) { $0.move(moving, to: state.id) }
        recordSaver.stateDidChange(state)
    }

    /// Merge All Windows: every other open normal window's workspaces move here, keeping their space, and those windows
    /// close; this window keeps its view and takes their last shown workspace per space it never showed.
    func mergeWindows(into state: WindowState) throws {
        let value = registry.value
        guard !value.isIncognito(state.id), incognitoSpaces[state.id] == nil else {
            throw ActionFailure.invalidTarget(RefusalStrings.incognitoMismatch)
        }
        let sources = value.openWindows.filter { $0.id != state.id && !value.isIncognito($0.id) }
        // A window's own Home stays in its window, which closes (as Close Other Windows), never as a surplus Home here.
        let moving = sources.flatMap(\.workspaceIDs).filter { !isWindowHome($0) }
        guard !sources.isEmpty else { return }
        try refuseClosingCreating(sources.map(\.id))
        // Front first, so the most recent window's pick wins for a space.
        let order = Dictionary(value.recency.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for source in sources.sorted(by: { order[$0.id, default: .max] < order[$1.id, default: .max] }) {
            guard let other = states[source.id] else { continue }
            var shown = other.profileWorkspaces
            if let workspaceID = other.workspaceID { shown[other.profileID] = workspaceID }
            for (space, id) in shown where space != state.profileID && state.profileWorkspaces[space] == nil { state.profileWorkspaces[space] = id }
        }
        carryLocalBrowserTabs(of: moving, from: sources, to: state)
        transition { registry in
            defer { for source in sources where registry.window(source.id)?.isOpen == true { _ = registry.close(source.id) } }
            return registry.move(moving, to: state.id)
        }
        recordSaver.stateDidChange(state)
    }

    private func isWindowHome(_ id: String) -> Bool { services.workspace(id: id)?.isWindowHome == true }

    /// A moved workspace's panes take their window-kept browser tabs (`localBrowserTabs`) along, from its own window only.
    private func carryLocalBrowserTabs(of moving: [String], from sources: [WindowRegistry.Window], to state: WindowState) {
        for source in sources { let workspaces = moving.filter(source.workspaceIDs.contains).compactMap { services.workspace(id: $0) }
            states[source.id]?.localBrowserTabs.move(panes: Set(workspaces.flatMap { $0.screens.flatMap(\.panes).map(\.id) }), to: state.localBrowserTabs)
        }
    }

    /// Refuses closing a window still creating a workspace (claim, placement, lane, provisional row): it would reopen it.
    private func refuseClosingCreating(_ windows: [String]) throws {
        let rows = PendingWorkspaceRows.shared.rows
        for window in windows {
            WorkspaceLanes.shared.prune(window) { self.services.workspace(id: $0) != nil }
            if pendingClaims.values.contains(window) || pendingPlacements.values.contains(where: { $0.window == window })
                || WorkspaceLanes.shared.outstandingCreates(in: window) > 0 || rows.contains(where: { $0.window == window }) {
                throw ActionFailure.invalidTarget(RefusalStrings.gatherWhileCreating)
            }
        }
    }

    /// The workspaces `profile` last showed, best first: shown by a window on it (front first), then remembered.
    private func lastShown(in profile: ProfileID, recency: [String], here state: WindowState) -> [String] {
        let others = recency.filter { $0 != state.id }.compactMap { states[$0] }
        let showing = others.filter { $0.profileID == profile }.compactMap(\.workspaceID)
        let remembered = ([state] + others).compactMap { $0.profileWorkspaces[profile] }
        return showing + remembered
    }
}
