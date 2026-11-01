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
    func switchProfile(_ profile: ProfileID, in state: WindowState, keepingHomes: Bool = false) {
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
            let adoptable = adoptableWorkspaces(in: profile, for: state.id).filter { !keepingHomes || !isAnyHome($0) }
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
            // A space naming a machine no listed machine serves (the list has not come, the account signed out)
            // has nothing to show and nowhere to create: the window stays where it is.
            if case .unresolved = services.machines.creation(in: profile) { return services.registry.refuse(CloudStrings.notConnected) }
            let previous = state.profileID
            state.enterProfile(profile)
            recordSaver.stateDidChange(state)
            // A space on a machine whose tree has not loaded (a paused Cloud machine, a link still connecting) may
            // hold workspaces already: wake it and show them once its tree loads, and create one only if it has none.
            if case let .machine(daemon) = services.machines.creation(in: profile), !daemon.store.isLoaded {
                let windowID = state.id
                Task { [services] in await enterLoaded(profile, on: daemon, in: windowID, from: previous); withExtendedLifetime(services) {} }
                return
            }
            Task { [services] in await createWorkspace(into: state.id); withExtendedLifetime(services) {} }
            return
        }
        let remembered = state.profileWorkspaces[profile].flatMap { visible.contains($0) ? $0 : nil }
        state.enterProfile(profile)
        select(remembered ?? visible.first, in: state)
    }

    /// The rest of a switch into a space whose machine had not loaded: once its tree loads, the window shows the
    /// space's workspaces no other window shows, else a new one. If the machine never loads, the window goes back
    /// to `previous` (never left empty) with the reason. Nothing happens if the window left the space meanwhile.
    private func enterLoaded(_ profile: ProfileID, on daemon: DaemonService, in windowID: String, from previous: ProfileID) async {
        var failure: String?
        do {
            if let machine = services.machines.cloudSession(of: daemon) { try await machine.connectedForSpace() }
            if await !CloudMove.holds(within: .seconds(60), until: { daemon.store.isLoaded }) { failure = CloudStrings.notConnected }
        } catch {
            failure = RefusalStrings.describe(error)
        }
        guard let state = states[windowID], state.profileID == profile else { return }
        if let failure {
            fallBack(preferring: previous, in: state)
            return services.registry.refuse(failure)
        }
        let adoptable = adoptableWorkspaces(in: profile, for: windowID)
        guard !adoptable.isEmpty else {
            _ = await createWorkspace(into: windowID)
            return
        }
        transition { $0.move(adoptable, to: windowID) }
        select(adoptable.first, in: state)
    }

    /// Leaves a Cloud space whose machine could not load, never through another wait: to `previous` when the window
    /// can show something there now, else to `default` when it can, else to `default` with a new workspace on this
    /// Mac. A wait into `previous` (another Cloud space that has not loaded) could fail back here and loop.
    func fallBack(preferring previous: ProfileID, in state: WindowState) {
        let members = registry.members(of: state.id), machines = services.machines
        // Visible here, or adoptable from a closed window: both take switchProfile's non-empty path, never a wait.
        for target in [previous, .defaultProfile] where target != state.profileID
            && (!WindowProfiles.visible(members, profile: target, machines: machines).isEmpty
                || !adoptableWorkspaces(in: target, for: state.id).isEmpty) {
            return switchProfile(target, in: state)
        }
        state.enterProfile(.defaultProfile)
        recordSaver.stateDidChange(state)
        let windowID = state.id
        Task { [services] in _ = await createWorkspace(on: services.daemon, into: windowID) }
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
    /// at its last shown workspace, or keeps its selection when already on it (none elsewhere: a plain switch).
    func bringSpace(_ profile: ProfileID, into state: WindowState) throws {
        let value = registry.value
        guard value.window(state.id) != nil else { throw ActionFailure.invalidTarget(RefusalStrings.windowNotReady) }
        let incognito = value.isIncognito(state.id) || incognitoSpaces[state.id] != nil || incognitoSpaces.values.contains(profile)
        if incognito { throw ActionFailure.invalidTarget(RefusalStrings.incognitoMismatch) }
        let machines = services.machines
        let sources = value.windows.filter { $0.id != state.id && !value.isIncognito($0.id) && incognitoSpaces[$0.id] == nil }
        // Only workspaces whose space is known move (one no session reports yet shows in every space); any Home stays.
        let moving = sources.flatMap { WindowProfiles.visible($0.workspaceIDs, profile: profile, machines: machines) }
            .filter { WindowProfiles.qualified($0, machines: machines) != nil && !isAnyHome($0) }
        try refuseClosingCreating(sources.filter { !Set($0.workspaceIDs).isDisjoint(with: moving) }.map(\.id))
        // A CLI or MCP run without focus permission leaves this window's view alone (as `RoomHandlers.startNewSpace`).
        let mayShow = ActionRunScope.viewChangeAllowed()
        guard !moving.isEmpty else {
            if mayShow { switchProfile(profile, in: state, keepingHomes: true) } // another window's Home stays there
            return
        }
        try refuseLocalTabs([state.id] + sources.filter { !Set($0.workspaceIDs).isDisjoint(with: moving) }.map(\.id))
        // A window already on the space keeps its selection; else the space's last shown workspace.
        var preferred: [String: [String]] = [:]
        if state.profileID != profile, mayShow {
            let candidates = Set(moving + WindowProfiles.visible(value.window(state.id)?.workspaceIDs ?? [], profile: profile, machines: machines))
            preferred[state.id] = lastShown(in: profile, recency: value.recency, here: state).filter(candidates.contains)
            state.enterProfile(profile)
        }
        transition(select: preferred) { $0.move(moving, to: state.id) }
        recordSaver.stateDidChange(state)
    }

    /// Merge All Windows: every other open normal window's workspaces move here, keeping their space, and those windows
    /// close; this window keeps its view and takes their last shown workspace per space it never showed.
    func mergeWindows(into state: WindowState) throws {
        let value = registry.value
        guard value.window(state.id) != nil else { throw ActionFailure.invalidTarget(RefusalStrings.windowNotReady) }
        if value.isIncognito(state.id) || incognitoSpaces[state.id] != nil { throw ActionFailure.invalidTarget(RefusalStrings.incognitoMismatch) }
        let sources = value.openWindows.filter { $0.id != state.id && !value.isIncognito($0.id) && incognitoSpaces[$0.id] == nil }
        // Only reported workspaces move; a Home and one not reported yet stay in their window, which closes.
        let moving = sources.flatMap(\.workspaceIDs).filter { services.workspace(id: $0).map { !$0.isAnyHome } == true }
        guard !sources.isEmpty else { return }
        try refuseClosingCreating(sources.map(\.id))
        try refuseLocalTabs((moving.isEmpty ? [] : [state.id]) + sources.map(\.id))
        let order = Dictionary(value.recency.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for source in sources.sorted(by: { order[$0.id, default: .max] < order[$1.id, default: .max] }) {
            guard let other = states[source.id] else { continue }
            var shown = other.profileWorkspaces
            if let workspaceID = other.workspaceID { shown[other.profileID] = workspaceID }
            for (space, id) in shown where space != state.profileID && state.profileWorkspaces[space] == nil { state.profileWorkspaces[space] = id }
        }
        transition { registry in
            defer { for source in sources where registry.window(source.id)?.isOpen == true { _ = registry.close(source.id) } }
            return registry.move(moving, to: state.id)
        }
        recordSaver.stateDidChange(state)
    }

    private func isAnyHome(_ id: String) -> Bool { services.workspace(id: id)?.isAnyHome == true }
    /// Refuses a move out of or into a window keeping its own browser tabs: keyed by pane id (repeats across machines).
    private func refuseLocalTabs(_ windows: [String]) throws {
        let keeps = windows.contains { states[$0]?.localBrowserTabs.all.isEmpty == false }
        if keeps { throw ActionFailure.invalidTarget(RefusalStrings.gatherLocalTabs) }
    }

    /// Refuses a move out of a window still creating a workspace (claim, placement, lane, provisional row): it may anchor
    /// there. A claim on a workspace the window already holds only protects one not reported yet (`protectIfUnknown`).
    private func refuseClosingCreating(_ windows: [String]) throws {
        for window in windows { let rows = PendingWorkspaceRows.shared.rows, held = Set(registry.value.window(window)?.workspaceIDs ?? [])
            WorkspaceLanes.shared.prune(window) { self.services.workspace(id: $0) != nil }
            if pendingClaims.contains(where: { $0.value == window && !held.contains($0.key) }) || pendingPlacements.values.contains(where: { $0.window == window })
                || WorkspaceLanes.shared.outstandingCreates(in: window) > 0 || rows.contains(where: { $0.window == window }) {
                throw ActionFailure.invalidTarget(RefusalStrings.gatherWhileCreating)
            }
        }
    }

    /// The workspaces `profile` last showed, best first: shown by a window on it (front first), then remembered.
    private func lastShown(in profile: ProfileID, recency: [String], here state: WindowState) -> [String] {
        let others = recency.filter { $0 != state.id }.compactMap { states[$0] }
        let showing = others.filter { $0.profileID == profile && registry.value.window($0.id)?.isOpen == true }.compactMap(\.workspaceID)
        let remembered = ([state] + others).compactMap { $0.profileWorkspaces[profile] }
        return showing + remembered
    }
}
