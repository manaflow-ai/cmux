import Foundation
import Observation

/// The app's observable state. Sources (mock now, link-backed later) write into it.
@MainActor
@Observable
public final class AppStore {
    public var teams: [Team] { didSet { refreshAttentionCount() } }
    public var activeTeamID: String { didSet { refreshAttentionCount() } }
    /// Every Mac's workspaces. Setting the same value again changes nothing
    /// and notifies no one: a Mac's whole list arrives on every tree update,
    /// and a view reading it rebuilt itself for an unchanged list.
    public var workspaces: [Workspace] {
        get {
            access(keyPath: \.workspaces)
            return workspaceStorage
        }
        set {
            guard newValue != workspaceStorage else { return }
            withMutation(keyPath: \.workspaces) { workspaceStorage = newValue }
            workspacesRevision &+= 1
            refreshAttentionCount()
        }
    }
    @ObservationIgnored private var workspaceStorage: [Workspace]
    /// Moves on every change of `workspaces`: what reads them can key a memo
    /// on it instead of comparing every workspace (read it with `workspaces`).
    @ObservationIgnored public private(set) var workspacesRevision = 0
    /// The active team's workspaces that need attention (the Workspaces tab
    /// badge). Kept as a value that changes only with the count: the
    /// workspaces change on every Mac tree update while an agent works, and a
    /// tab bar reading them re-rendered (and rebuilt its items) each time.
    public private(set) var attentionCount = 0

    private func refreshAttentionCount() {
        let count = activeWorkspaces.count(where: \.needsAttention)
        if count != attentionCount { attentionCount = count }
    }
    public var feed: [FeedEvent]
    /// The last tab the user had open per workspace on this device,
    /// persisted across launches through `tabMemory`.
    public private(set) var lastTabByWorkspace: [String: String] = [:]
    @ObservationIgnored private let tabMemory: TabMemory
    /// Load state of the active team's live data (skeletons until the first
    /// `hello` frame; a failure shows the list-level error state).
    public var teamDataState: LoadState = .loaded
    /// Whether the device has network (drives the offline banner).
    public var isOffline = false
    /// Plain live link status per Mac id ("Connected", "Reconnecting…"),
    /// shown in the Workspaces Mac section header. Empty in mock mode.
    public var macLinkStatus: [String: String] = [:]
    /// Raw connection and service details, shown only in Settings diagnostics.
    public var macLinkDiagnostics: [String: String] = [:]
    /// Live mode: where each Mac's workspaces came from (cached, live, ...).
    /// Empty states read this, never `workspaces` alone (`macDataPhase`).
    public var macData: [String: MacDataMachine] = [:]
    /// Live mode: this phone's connection to each Mac it dials.
    public var macConnection: [String: MacConnection] = [:]
    /// What each Mac's host said it does (`version` service `capabilities`), for
    /// Macs this phone has linked to. Absent: unknown (older host, or never linked).
    public var macCapabilities: [String: Set<String>] = [:]
    /// True once live data drives the store (false in mock mode).
    public var tracksMacData = false
    /// How many Macs the signed-in account has in any team or its personal
    /// space (`GET /v1/me/macs`); nil until discovery first answers, and in
    /// mock mode. Zero means the Mac, if any, is signed in to another account.
    public var accountMacCount: Int?
    /// Optimistic workspaces still being created on their Mac. A tree
    /// refresh keeps them until the creation settles.
    public private(set) var pendingWorkspaceIDs: Set<String> = []
    /// Group edits (collapse, rename, color, delete, move) the Mac's list
    /// has not shown back yet: a tree refresh keeps them (`PendingGroupEdits`).
    @ObservationIgnored var groupEdits = PendingGroupEdits()
    /// The clock group edits are confirmed against (tests set it).
    @ObservationIgnored public var now: () -> Date = Date.init

    /// Forgets the group edits not yet shown back (sign-out, another account).
    public func resetGroupEdits() {
        groupEdits.removeAll()
    }
    /// Placeholder id → the real workspace id once its creation succeeds, so
    /// a screen opened on the placeholder follows the real workspace.
    public private(set) var workspaceAliases: [String: String] = [:]

    /// Phases of a remote load.
    public enum LoadState: Hashable, Sendable {
        case loading, loaded, failed
    }

    public init(teams: [Team], activeTeamID: String, workspaces: [Workspace], feed: [FeedEvent], tabMemory: TabMemory = .standard) {
        self.tabMemory = tabMemory
        lastTabByWorkspace = tabMemory.load()
        self.teams = teams
        self.activeTeamID = activeTeamID
        workspaceStorage = workspaces
        self.feed = feed
        refreshAttentionCount()
    }

    public var activeTeam: Team? {
        teams.first { $0.id == activeTeamID }
    }

    public func selectTeam(_ id: String) {
        guard teams.contains(where: { $0.id == id }) else { return }
        activeTeamID = id
        UserDefaults.standard.set(id, forKey: Self.lastTeamKey)
    }

    /// Setup's "Personal": makes the personal space active when the store
    /// lists it (mock data, or live once the account's spaces have loaded);
    /// false when it isn't listed yet (the live coordinator adds it).
    @discardableResult
    public func selectPersonalSpace() -> Bool {
        guard let id = teams.first(where: \.isPersonalSpace)?.id else { return false }
        selectTeam(id)
        return true
    }

    public func setAppearance(_ appearance: TeamAppearance, for teamID: String) {
        guard let index = teams.firstIndex(where: { $0.id == teamID }) else { return }
        teams[index].appearance = appearance
        if let data = try? JSONEncoder().encode(appearance) {
            UserDefaults.standard.set(data, forKey: Self.appearanceKey(teamID))
        }
    }

    /// Replaces the team list with the signed-in account's Stack teams. Macs
    /// stay mock until the `cmux-mobile-api` presence link exists: each team gets
    /// one of the sample Mac sets by position. Appearance is per user per team
    /// and persists locally until `PUT /v1/teams/:id/prefs` is wired.
    public func applyAccountTeams(_ accountTeams: [AccountTeam], selectedID: String?) {
        #if DEBUG
        let sampleMacs = AppStore.mock().teams.map(\.macs)
        #else
        // No sample Macs outside DEBUG: Macs come only from live data.
        let sampleMacs: [[MacDevice]] = []
        #endif
        teams = accountTeams.enumerated().map { index, team in
            Team(
                id: team.id,
                name: team.name,
                appearance: Self.storedAppearance(team.id),
                macs: sampleMacs.isEmpty ? [] : sampleMacs[index % sampleMacs.count]
            )
        }
        let remembered = UserDefaults.standard.string(forKey: Self.lastTeamKey)
        let candidates = [selectedID, remembered, teams.first?.id].compactMap { $0 }
        activeTeamID = candidates.first { id in teams.contains { $0.id == id } } ?? ""
    }

    /// Live mode: the account's teams with no sample Macs (Macs come from
    /// `GET /v1/teams/:id/macs` and presence). Keeps Macs already loaded.
    public func applyLiveTeams(_ accountTeams: [AccountTeam], selectedID: String?) {
        let known = Dictionary(teams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        teams = accountTeams.map { team in
            Team(id: team.id, name: team.name, appearance: known[team.id]?.appearance ?? Self.storedAppearance(team.id),
                 macs: known[team.id]?.macs ?? [])
        }
        let remembered = UserDefaults.standard.string(forKey: Self.lastTeamKey)
        let candidates = [selectedID, remembered, teams.first?.id].compactMap { $0 }
        activeTeamID = candidates.first { id in teams.contains { $0.id == id } } ?? ""
    }

    /// Replaces a team's Macs (presence snapshot or update).
    public func setMacs(_ macs: [MacDevice], teamID: String) {
        guard let index = teams.firstIndex(where: { $0.id == teamID }), teams[index].macs != macs else { return }
        teams[index].macs = macs
    }

    /// Replaces one Mac's workspaces, keeping the others.
    public func replaceWorkspaces(macID: String, with next: [Workspace]) {
        var next = next
        groupEdits.apply(to: &next, now: now())
        let merged = Self.reconciled(workspaces, macID: macID, with: next, keeping: pendingWorkspaceIDs)
        if merged != workspaces { workspaces = merged }
    }

    /// Reconciles metadata for existing rows without rebuilding or comparing
    /// every tab on the Mac. Topology changes still use `replaceWorkspaces`.
    public func updateWorkspaces(macID: String, rows: [Workspace]) {
        var rows = rows
        groupEdits.apply(to: &rows, now: now())
        for row in rows {
            guard !pendingWorkspaceIDs.contains(row.id),
                  let index = workspaces.firstIndex(where: { $0.macID == macID && $0.id == row.id }),
                  workspaces[index] != row else { continue }
            workspaces[index] = row
        }
    }

    /// `current` with one Mac's rows replaced by `next` in place: the Mac's
    /// block stays where its first (cached or live) row was, so the first live
    /// answer after a launch does not move that Mac's rows behind every other
    /// Mac's (a reorder the list animates). Other Macs' rows and this phone's
    /// pending creations stay where they are.
    nonisolated static func reconciled(_ current: [Workspace], macID: String, with next: [Workspace],
                                       keeping pending: Set<String>) -> [Workspace] {
        var result: [Workspace] = []
        result.reserveCapacity(current.count + next.count)
        var placed = false
        for workspace in current {
            if workspace.macID == macID, !pending.contains(workspace.id) {
                if !placed {
                    result += next
                    placed = true
                }
            } else {
                result.append(workspace)
            }
        }
        if !placed { result += next }
        return result
    }

    /// A Stack Auth team as the account reports it.
    public struct AccountTeam: Hashable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    static let lastTeamKey = "cmuxMobile.lastTeamID"
    private static func appearanceKey(_ teamID: String) -> String { "cmuxMobile.teamAppearance.\(teamID)" }

    private static func storedAppearance(_ teamID: String) -> TeamAppearance? {
        guard let data = UserDefaults.standard.data(forKey: appearanceKey(teamID)) else { return nil }
        return try? JSONDecoder().decode(TeamAppearance.self, from: data)
    }

    /// Workspaces on the active team's Macs.
    public var activeWorkspaces: [Workspace] {
        let macIDs = Set(activeTeam?.macs.map(\.id) ?? [])
        return workspaces.filter { macIDs.contains($0.macID) }
    }

    /// The tab a workspace opens to: the last one used on this device, else
    /// the tab on screen on the Mac, else its first tab.
    public func openingTab(for workspace: Workspace) -> WorkspaceTab? {
        if let id = lastTabByWorkspace[workspace.id], let tab = workspace.tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let id = workspace.activeTabID, let tab = workspace.tabs.first(where: { $0.id == id }) {
            return tab
        }
        return workspace.tabs.first
    }

    /// When this device last opened each workspace (this session): "Done"
    /// stays cleared until the workspace has newer activity.
    public private(set) var seenAt: [String: Date] = [:]

    public func markSeen(_ workspaceID: String, at date: Date = Date()) {
        seenAt[resolvedWorkspaceID(workspaceID)] = date
    }

    /// Records the tab on screen in a workspace (every activation).
    public func noteOpened(tabID: String, in workspaceID: String) {
        let workspaceID = resolvedWorkspaceID(workspaceID)
        guard lastTabByWorkspace[workspaceID] != tabID else { return }
        lastTabByWorkspace[workspaceID] = tabID
        tabMemory.save(lastTabByWorkspace)
    }

    public func workspace(id: String) -> Workspace? {
        let id = resolvedWorkspaceID(id)
        return workspaces.first { $0.id == id }
    }

    /// Follows a created placeholder to its real workspace id.
    public func resolvedWorkspaceID(_ id: String) -> String {
        workspaceAliases[id] ?? id
    }

    /// Workspaces this phone just created: their first tab opens ready to
    /// type (keyboard up), like a new chat in ChatGPT or Claude.
    public private(set) var focusOnOpenWorkspaceIDs: Set<String> = []

    public func requestFocusOnOpen(_ workspaceID: String) {
        focusOnOpenWorkspaceIDs.insert(resolvedWorkspaceID(workspaceID))
    }

    /// Whether a workspace has a focus request waiting (placeholder or the
    /// real id it became). A read: building a workspace screen, which a
    /// navigation destination does on every update, calls only this.
    public func wantsFocusOnOpen(_ workspaceID: String) -> Bool {
        focusOnOpenWorkspaceIDs.contains(workspaceID) || focusOnOpenWorkspaceIDs.contains(resolvedWorkspaceID(workspaceID))
    }

    /// True once per request (placeholder or the real id it became). Writes
    /// only when there is a request: `Set.remove` on an observed property
    /// notifies observers even when it removes nothing, and a view update
    /// that notifies what it reads re-runs itself forever (verify/e2e-matrix.md #4).
    public func takeFocusOnOpen(_ workspaceID: String) -> Bool {
        guard wantsFocusOnOpen(workspaceID) else { return false }
        return focusOnOpenWorkspaceIDs.remove(workspaceID) != nil
            || focusOnOpenWorkspaceIDs.remove(resolvedWorkspaceID(workspaceID)) != nil
    }

    public func isPending(_ workspaceID: String) -> Bool {
        pendingWorkspaceIDs.contains(workspaceID)
    }

    /// Adds an optimistic workspace (creation in flight).
    public func insertPending(_ workspace: Workspace) {
        pendingWorkspaceIDs.insert(workspace.id)
        workspaces.append(workspace)
    }

    /// The creation succeeded: the placeholder becomes `real`. When the ids
    /// differ (the Mac assigned its own), the placeholder row is dropped,
    /// `real` is added unless a tree refresh already brought it, and the
    /// placeholder id aliases to it.
    public func resolvePending(_ placeholderID: String, with real: Workspace) {
        pendingWorkspaceIDs.remove(placeholderID)
        if real.id == placeholderID {
            if let index = workspaces.firstIndex(where: { $0.id == placeholderID }) { workspaces[index] = real }
            return
        }
        workspaces.removeAll { $0.id == placeholderID }
        if !workspaces.contains(where: { $0.id == real.id }) { workspaces.append(real) }
        workspaceAliases[placeholderID] = real.id
    }

    /// The creation failed: the placeholder disappears.
    public func removePending(_ placeholderID: String) {
        pendingWorkspaceIDs.remove(placeholderID)
        workspaces.removeAll { $0.id == placeholderID }
        if lastTabByWorkspace.removeValue(forKey: placeholderID) != nil { tabMemory.save(lastTabByWorkspace) }
    }

    /// Renames a workspace in place. Returns the previous title (for a
    /// rollback), or nil when the workspace is unknown.
    @discardableResult
    public func renameWorkspace(_ workspaceID: String, to title: String) -> String? {
        let workspaceID = resolvedWorkspaceID(workspaceID)
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let old = workspaces[index].title
        workspaces[index].title = title
        return old
    }

    /// Removes a closed workspace and forgets its last tab. Returns it with
    /// its position, so a refused close can put it back.
    @discardableResult
    public func removeWorkspace(_ workspaceID: String) -> (workspace: Workspace, index: Int)? {
        let workspaceID = resolvedWorkspaceID(workspaceID)
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let removed = workspaces.remove(at: index)
        if lastTabByWorkspace.removeValue(forKey: workspaceID) != nil { tabMemory.save(lastTabByWorkspace) }
        return (removed, index)
    }

    /// Puts back a workspace whose close the Mac refused.
    public func restoreWorkspace(_ workspace: Workspace, at index: Int) {
        guard !workspaces.contains(where: { $0.id == workspace.id }) else { return }
        workspaces.insert(workspace, at: min(index, workspaces.count))
    }

    /// Appends a tab to a workspace (new tabs go last, as in Safari).
    public func appendTab(_ tab: WorkspaceTab, to workspaceID: String) {
        let workspaceID = resolvedWorkspaceID(workspaceID)
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].tabs.append(tab)
        workspaces[index].lastActivityAt = Date()
    }

    /// Renames a tab in place; returns the old title (for a rollback).
    @discardableResult
    public func renameTab(_ tabID: String, in workspaceID: String, to title: String) -> String? {
        let workspaceID = resolvedWorkspaceID(workspaceID)
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let position = workspaces[index].tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let old = workspaces[index].tabs[position].title
        workspaces[index].tabs[position].title = title
        return old
    }

    /// Changes a tab in place; returns it as it was (for a rollback).
    @discardableResult
    public func updateTab(_ tabID: String, in workspaceID: String, _ change: (inout WorkspaceTab) -> Void) -> WorkspaceTab? {
        let workspaceID = resolvedWorkspaceID(workspaceID)
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let position = workspaces[index].tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let old = workspaces[index].tabs[position]
        change(&workspaces[index].tabs[position])
        return old
    }

    /// Moves a tab to `position` in its workspace; returns where it was (for a rollback).
    @discardableResult
    public func moveTab(_ tabID: String, in workspaceID: String, to position: Int) -> Int? {
        let workspaceID = resolvedWorkspaceID(workspaceID)
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let from = workspaces[index].tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        let tab = workspaces[index].tabs.remove(at: from)
        workspaces[index].tabs.insert(tab, at: max(0, min(position, workspaces[index].tabs.count)))
        return from
    }

    /// Puts back a tab whose close the Mac refused, at its old position.
    public func insertTab(_ tab: WorkspaceTab, at position: Int, in workspaceID: String) {
        let workspaceID = resolvedWorkspaceID(workspaceID)
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              !workspaces[index].tabs.contains(where: { $0.id == tab.id }) else { return }
        workspaces[index].tabs.insert(tab, at: min(position, workspaces[index].tabs.count))
    }

    /// Removes a tab. Returns the tab that should be on screen next when the
    /// removed one was the remembered tab: its right neighbor, else its left.
    @discardableResult
    public func removeTab(_ tabID: String, from workspaceID: String) -> WorkspaceTab? {
        let workspaceID = resolvedWorkspaceID(workspaceID)
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let position = workspaces[index].tabs.firstIndex(where: { $0.id == tabID }) else { return nil }
        workspaces[index].tabs.remove(at: position)
        let tabs = workspaces[index].tabs
        let next = tabs.isEmpty ? nil : tabs[min(position, tabs.count - 1)]
        if lastTabByWorkspace[workspaceID] == tabID {
            if let next {
                noteOpened(tabID: next.id, in: workspaceID)
            } else {
                lastTabByWorkspace[workspaceID] = nil
                tabMemory.save(lastTabByWorkspace)
            }
        }
        return next
    }
}
