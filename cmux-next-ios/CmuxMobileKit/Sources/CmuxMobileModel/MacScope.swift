import Foundation
import Observation

/// Which Macs the Workspaces list and Home show: every Mac in the team
/// (mixed, no per-Mac grouping) or one Mac. The toolbar's filter menu.
public enum MacScope: Hashable, Sendable {
    case all
    case mac(String)

    public var macID: String? {
        if case let .mac(id) = self { id } else { nil }
    }
}

/// The Mac filter Workspaces and Home share, remembered per team. A Mac that has
/// left the team (or was never in it) reads as All.
@MainActor
@Observable
public final class MacFilter {
    /// By team id; only teams this device has chosen a Mac for.
    private var scopes: [String: MacScope] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    public static let keyPrefix = "cmuxMobile.workspaces.macFilter."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ teamID: String) -> String { Self.keyPrefix + teamID }

    /// The stored scope for a team, resolved against its current Macs.
    public func scope(in team: Team?) -> MacScope {
        guard let team else { return .all }
        let stored = scopes[team.id] ?? defaults.string(forKey: key(team.id)).map(MacScope.mac) ?? .all
        return Self.resolve(stored, macs: team.macs)
    }

    public func select(_ scope: MacScope, in teamID: String) {
        scopes[teamID] = scope
        if let id = scope.macID {
            defaults.set(id, forKey: key(teamID))
        } else {
            defaults.removeObject(forKey: key(teamID))
        }
    }

    /// A Mac scope whose Mac is gone falls back to All Macs.
    public nonisolated static func resolve(_ scope: MacScope, macs: [MacDevice]) -> MacScope {
        guard let id = scope.macID else { return .all }
        return macs.contains { $0.id == id } ? scope : .all
    }
}

extension MacScope {
    /// The filter menu's Macs after All: online first, each group in team order.
    public static func menuOrder(_ macs: [MacDevice]) -> [MacDevice] {
        macs.filter(\.isOnline) + macs.filter { !$0.isOnline }
    }
}
