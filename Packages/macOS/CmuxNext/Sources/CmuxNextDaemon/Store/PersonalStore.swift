import Foundation
public import Observation

/// The home session's personal state besides rooms (`DaemonStore.profiles`):
/// follows, pins, personal groups, per-workspace organization and the
/// session registry (plans/cmux-next/data-model.md 3.3). Replaced as a whole
/// on each snapshot; `revision` is the daemon's `personal_revision`.
@Observable @MainActor
public final class PersonalStore {
    /// False on a daemon without `profiles-v1` (read-only fallback).
    public internal(set) var isLoaded = false
    public internal(set) var revision: UInt64 = 0
    public internal(set) var sessions: [SessionRecord] = [] {
        didSet { sessionIndex = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// Sessions each room follows.
    public internal(set) var follows: [ProfileID: Set<String>] = [:]
    public internal(set) var pins: [WorkspacePin] = [] {
        didSet { pinIndex = personalPinIndex(pins) }
    }
    /// Personal workspace groups in order, each in one room.
    public internal(set) var groups: [WorkspaceGroupModel] = []
    /// Room of each personal group.
    public internal(set) var groupRooms: [WorkspaceGroupID: ProfileID] = [:]
    /// Personal organization per qualified workspace.
    public internal(set) var workspaces: [PersonalWorkspace] = [] {
        didSet { workspaceIndex = personalWorkspaceIndex(workspaces) }
    }
    /// Per-terminal themes, keyed `session_id` then terminal key.
    public internal(set) var terminalThemes: [String: [String: String]] = [:]
    /// Browser profile records (`browser-profiles-v1`), in order.
    public internal(set) var browserProfiles: [BrowserProfileSnapshot] = []
    /// Groups a client is deleting because they lost their last member
    /// (cx-rcby). Client state, never from the daemon: the sidebar hides an
    /// ending group that shows no member until the delete lands.
    public var endingGroups: Set<WorkspaceGroupID> = []

    /// `workspaces` by session then key, rebuilt when the list is set: a lookup per row or per tab
    /// (sidebar rows, tab badges, themes) is O(1), not a scan of every workspace (space-switch-fast).
    @ObservationIgnored private var workspaceIndex: [String: [String: PersonalWorkspace]] = [:]
    /// `sessions` by id, rebuilt when the list is set.
    @ObservationIgnored private var sessionIndex: [String: SessionRecord] = [:]
    /// `pins` as session, then workspace key, to room, rebuilt when the list is set: a room lookup per switch or per
    /// row is O(1), never a pass over every pin (switch-scale: each workspace select and space switch built it).
    @ObservationIgnored private var pinIndex: [String: [String: ProfileID]] = [:]

    public init() {}

    /// The own theme of a session-qualified terminal.
    public func terminalTheme(session: String, terminal: String) -> String? { terminalThemes[session]?[terminal] }

    // Each lookup reads its list (observed as before), then answers from the index.
    public func session(_ id: String) -> SessionRecord? {
        _ = sessions
        return sessionIndex[id]
    }
    public func group(_ id: WorkspaceGroupID) -> WorkspaceGroupModel? { groups.first { $0.id == id } }
    /// The group the sidebar-document group item `id` names, as the daemon reads it: `itm_g_<id>` first.
    public func group(item id: String) -> WorkspaceGroupModel? {
        Self.legacyGroupID(item: id).flatMap(group) ?? group(WorkspaceGroupID(rawValue: id))
    }
    /// The group a sidebar-document group item `itm_g_<id>` names (the daemon's `legacy_group_id`):
    /// a group migrated or synced from this store. A group the document made keeps its own id.
    public nonisolated static func legacyGroupID(item: String) -> WorkspaceGroupID? {
        item.hasPrefix("itm_g_") ? WorkspaceGroupID(rawValue: String(item.dropFirst(6))) : nil
    }

    /// Every pin as session, then workspace key, to its one room. Reads `pins` (observed as before), then returns the
    /// index kept with it: no work per call.
    public var pinnedRooms: [String: [String: ProfileID]] {
        _ = pins
        return pinIndex
    }

    public func workspace(session: String, key: String) -> PersonalWorkspace? {
        _ = workspaces
        return workspaceIndex[session]?[key]
    }
}

/// `workspaces` by session then key; the first row wins, as a scan would.
private func personalWorkspaceIndex(_ workspaces: [PersonalWorkspace]) -> [String: [String: PersonalWorkspace]] {
    var index: [String: [String: PersonalWorkspace]] = [:]
    for workspace in workspaces where index[workspace.sessionID]?[workspace.workspaceKey.rawValue] == nil {
        index[workspace.sessionID, default: [:]][workspace.workspaceKey.rawValue] = workspace
    }
    return index
}

/// `pins` by session then key; the last pin of a workspace wins, as building a dictionary from the list did.
private func personalPinIndex(_ pins: [WorkspacePin]) -> [String: [String: ProfileID]] {
    var index: [String: [String: ProfileID]] = [:]
    for pin in pins { index[pin.sessionID, default: [:]][pin.workspaceKey.rawValue] = pin.profile }
    return index
}

extension DaemonStore {
    /// Whether this daemon serves personal state (`profiles-v1`).
    public var supportsProfiles: Bool { identity?.supports(DaemonCapability.profiles.rawValue) ?? false }

    /// Whether personal groups carry a place among the loose workspaces
    /// (`personal-mixed-order-v1`).
    public var supportsPersonalMixedOrder: Bool { identity?.supports(DaemonCapability.personalMixedOrder.rawValue) ?? false }

    func applyPersonal(_ state: PersonalState?) {
        guard let state else {
            if personal.isLoaded { personal = PersonalStore() }
            if !profiles.isEmpty { profiles = [] }
            return
        }
        if let reordered = reconcile(profiles, with: state.profiles, id: \.id, make: ProfileModel.init, update: { $0.update($1) }) {
            profiles = reordered
        }
        let store = personal
        if !store.isLoaded { store.isLoaded = true }
        if store.revision != state.revision { store.revision = state.revision }
        if store.sessions != state.sessions { store.sessions = state.sessions }
        let follows = Dictionary(state.profiles.map { ($0.id, Set($0.follows)) }, uniquingKeysWith: { first, _ in first })
        if store.follows != follows { store.follows = follows }
        if store.pins != state.pins { store.pins = state.pins }
        if let reordered = reconcile(store.groups, with: state.groups, id: \.id, make: WorkspaceGroupModel.init, update: { $0.update($1) }) {
            store.groups = reordered
        }
        let rooms = Dictionary(state.groups.map { ($0.id, $0.profile ?? .defaultProfile) }, uniquingKeysWith: { first, _ in first })
        if store.groupRooms != rooms { store.groupRooms = rooms }
        if store.workspaces != state.workspaces { store.workspaces = state.workspaces }
        let terminals = Dictionary(grouping: state.terminals, by: \.sessionID).mapValues {
            Dictionary($0.map { ($0.terminalKey, $0.theme) }, uniquingKeysWith: { first, _ in first })
        }
        if store.terminalThemes != terminals { store.terminalThemes = terminals }
        if store.browserProfiles != state.browserProfiles { store.browserProfiles = state.browserProfiles }
    }
}
