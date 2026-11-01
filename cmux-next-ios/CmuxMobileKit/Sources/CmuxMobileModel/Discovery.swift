import Foundation

/// The account's team list as it loads. "Not loaded yet" is never "no
/// teams": setup shows Create Team only for `.loaded` with an empty list,
/// a loading state before that, and Retry after a failure.
public struct TeamListState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading, loaded, failed(String)
    }

    public private(set) var phase: Phase
    /// The account's Stack teams (never the personal space). Kept across a
    /// failed refresh.
    public private(set) var teams: [AppStore.AccountTeam]

    public init(phase: Phase = .loading, teams: [AppStore.AccountTeam] = []) {
        self.phase = phase
        self.teams = teams
    }

    /// A new session: nothing is known yet.
    public mutating func reset() {
        phase = .loading
        teams = []
    }

    /// Retry after a failure: loading again (a known list stays shown).
    public mutating func retry() {
        if case .failed = phase { phase = .loading }
    }

    /// The auth coordinator published its list. An empty list is its
    /// initial value, not an answer, so only a non-empty one counts.
    public mutating func published(_ teams: [AppStore.AccountTeam]) {
        guard !teams.isEmpty else { return }
        self.teams = teams
        phase = .loaded
    }

    /// The account's own team fetch answered; an empty list is a real "no teams".
    public mutating func fetched(_ teams: [AppStore.AccountTeam]) {
        self.teams = teams
        phase = .loaded
    }

    /// The fetch failed. A list that already loaded stays loaded.
    public mutating func failed(_ message: String) {
        guard phase != .loaded else { return }
        phase = .failed(message)
    }

    public var isLoaded: Bool { phase == .loaded }
}

/// One of the account's own Macs in any of its spaces (`GET /v1/me/macs`).
public struct DiscoveredMac: Hashable, Sendable {
    public var id: String
    public var name: String
    public var isOnline: Bool
    public var lastSeenAt: Date?
    /// The team (or `personal-<userId>`) the Mac is registered in.
    public var teamID: String
    /// Who registered it (the caller: `/v1/me/macs` lists only the caller's own Macs).
    public var ownerUserID: String?
    /// The computer it runs on (``MacDevice/machineID``).
    public var machineID: String?

    public init(id: String, name: String, isOnline: Bool, lastSeenAt: Date? = nil, teamID: String,
                ownerUserID: String? = nil, machineID: String? = nil) {
        self.id = id
        self.name = name
        self.isOnline = isOnline
        self.lastSeenAt = lastSeenAt
        self.teamID = teamID
        self.ownerUserID = ownerUserID
        self.machineID = machineID
    }

    /// The Mac as the team lists it; what this look does not say (an older Worker's
    /// missing machine id) is kept from `known`.
    func device(keeping known: MacDevice?) -> MacDevice {
        MacDevice(id: id, name: name, isOnline: isOnline, lastSeenAt: lastSeenAt,
                  ownerUserID: ownerUserID ?? known?.ownerUserID, machineID: machineID ?? known?.machineID)
    }

    /// The Mac in its team: a Mac that moves to another team is a new arrival there.
    public var placement: String { "\(id)\u{0}\(teamID)" }
}

extension AppStore {
    /// Merges the account's own Macs into the teams: each Mac is shown in the
    /// team it is registered in now (and removed from any other team it was
    /// listed in, after a move), other members' Macs stay as they are. The
    /// personal space joins the list as `personal` when a Mac lives there.
    public func mergeDiscoveredMacs(_ macs: [DiscoveredMac], personal: AccountTeam? = nil) {
        if let personal, macs.contains(where: { $0.teamID == personal.id }), !teams.contains(where: { $0.id == personal.id }) {
            teams.append(Team(id: personal.id, name: personal.name))
        }
        let byID = Dictionary(macs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in teams.indices {
            let teamID = teams[index].id
            var next = teams[index].macs.filter { mac in byID[mac.id].map { $0.teamID == teamID } ?? true }
            for mac in macs where mac.teamID == teamID {
                if let at = next.firstIndex(where: { $0.id == mac.id }) {
                    next[at] = mac.device(keeping: next[at])
                } else {
                    next.append(mac.device(keeping: nil))
                }
            }
            if next != teams[index].macs { teams[index].macs = next }
        }
    }

    /// The team the phone should move to so it reaches one of the account's
    /// Macs, or nil to stay. Only while the active team has no online Mac:
    /// a Mac that just came online elsewhere, or moved there while online
    /// (its `placement` not in `previouslyOnline`; nil means this is the
    /// first look), moves it, and so does any online
    /// Mac elsewhere while the active team has no Mac at all, unless the
    /// user picked this team themselves (`pinnedTeamID`).
    public func teamToFollow(_ macs: [DiscoveredMac], previouslyOnline: Set<String>?, pinnedTeamID: String? = nil) -> Team? {
        let active = activeTeam
        guard !(active?.macs.contains(where: \.isOnline) ?? false) else { return nil }
        let waitingForAnyMac = active?.macs.isEmpty ?? true
        let reachable = macs.filter { mac in
            mac.isOnline && mac.teamID != activeTeamID && teams.contains { $0.id == mac.teamID }
        }
        let candidates = reachable.filter { mac in
            let appeared = previouslyOnline.map { !$0.contains(mac.placement) } ?? true
            return appeared || (waitingForAnyMac && pinnedTeamID != activeTeamID)
        }
        // The first such team in the sidebar's order.
        return teams.first { team in candidates.contains { $0.teamID == team.id } }
    }

    /// For the empty state: another team with one of the account's Macs
    /// (online first), so the user can switch to it.
    public func teamWithMacsElsewhere() -> (team: Team, mac: MacDevice)? {
        let others = teams.filter { $0.id != activeTeamID && !$0.macs.isEmpty }
        if let team = others.first(where: { $0.macs.contains(where: \.isOnline) }), let mac = team.macs.first(where: \.isOnline) {
            return (team, mac)
        }
        return others.first.map { ($0, $0.macs[0]) }
    }
}

extension AppStore {
    /// Preference keys that belong to the signed-in account (its teams, Macs,
    /// workspaces and setup), removed on sign-out so the next account starts
    /// clean. Device preferences (appearance, terminal, developer) stay.
    public nonisolated static func isAccountPreference(_ key: String) -> Bool {
        let exact: Set<String> = ["cmuxMobile.lastTeamID", "cmuxMobile.setupComplete", "cmuxMobile.lastTabByWorkspace", "cmuxMobile.workspaces.newMac", "cmuxMobile.auth.selectedTeam"]
        let prefixes = ["cmuxMobile.teamAppearance.", "cmuxMobile.live.mac.", "cmuxMobile.workspaces.recentDirectories.", "cmuxMobile.workspaces.macFilter."]
        return exact.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }

    /// Sign-out: forgets the account's teams, Macs, workspaces and link
    /// status, and its stored preferences (`isAccountPreference`).
    public func resetForSignOut(defaults: UserDefaults = .standard) {
        teams = []
        activeTeamID = ""
        workspaces = []
        macLinkStatus = [:]
        macLinkDiagnostics = [:]
        macData = [:]
        macConnection = [:]
        accountMacCount = nil
        teamDataState = .loading
        for key in defaults.dictionaryRepresentation().keys where Self.isAccountPreference(key) {
            defaults.removeObject(forKey: key)
        }
    }
}
