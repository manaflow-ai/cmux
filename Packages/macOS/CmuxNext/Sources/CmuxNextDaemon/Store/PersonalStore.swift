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
    public internal(set) var sessions: [SessionRecord] = []
    /// Sessions each room follows.
    public internal(set) var follows: [ProfileID: Set<String>] = [:]
    public internal(set) var pins: [WorkspacePin] = []
    /// Personal workspace groups in order, each in one room.
    public internal(set) var groups: [WorkspaceGroupModel] = []
    /// Room of each personal group.
    public internal(set) var groupRooms: [WorkspaceGroupID: ProfileID] = [:]
    /// Personal organization per qualified workspace.
    public internal(set) var workspaces: [PersonalWorkspace] = []
    /// Per-terminal themes, keyed `session_id` then terminal key.
    public internal(set) var terminalThemes: [String: [String: String]] = [:]
    /// Browser profile records (`browser-profiles-v1`), in order.
    public internal(set) var browserProfiles: [BrowserProfileSnapshot] = []

    public init() {}

    /// The own theme of a session-qualified terminal.
    public func terminalTheme(session: String, terminal: String) -> String? { terminalThemes[session]?[terminal] }

    public func session(_ id: String) -> SessionRecord? { sessions.first { $0.id == id } }
    public func group(_ id: WorkspaceGroupID) -> WorkspaceGroupModel? { groups.first { $0.id == id } }

    public func workspace(session: String, key: String) -> PersonalWorkspace? {
        workspaces.first { $0.sessionID == session && $0.workspaceKey.rawValue == key }
    }
}

extension DaemonStore {
    /// Whether this daemon serves personal state (`profiles-v1`).
    public var supportsProfiles: Bool { identity?.supports(DaemonCapabilities.shared.profiles) ?? false }

    /// Whether personal groups carry a place among the loose workspaces
    /// (`personal-mixed-order-v1`).
    public var supportsPersonalMixedOrder: Bool { identity?.supports(DaemonCapabilities.shared.personalMixedOrder) ?? false }

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
