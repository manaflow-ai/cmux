import Foundation

/// Which of the account's Macs the Mac filter, Workspaces, Home and the links
/// list: every cmux build the account registered, each as its own Mac.
///
/// Every cmux build registers its own device (its own id, identity key and
/// paired phones), and each one is listed by the name it registered with: the
/// Stable lane by the computer's name, any other build with its lane
/// (`MacBook Pro (NIGHTLY)`, CmuxNextMobile `MobileHostDeviceName`). Two builds
/// on one computer are two Macs here, never folded into one: they run apart,
/// approve phones apart and each can be chosen and removed on its own.
/// (`MacDevice.machineID` still says which computer a build runs on; the list
/// does not group by it.)
///
/// A name is never an identity: several Macs can share one (they stay apart,
/// with the `MacNameDisambiguation` tag).
public struct MacRoster: Equatable, Sendable {
    /// Listed: each Mac record once, in the given order.
    public let visible: [MacDevice]

    /// `preferring` is kept for callers that name the picked build (``Team/pickedMacID``); with
    /// every build listed on its own there is nothing to prefer it over.
    public init(_ macs: [MacDevice], preferring _: String? = nil) {
        var seen = Set<String>()
        visible = macs.filter { seen.insert($0.id).inserted }
    }

    /// The account's listed Macs (the same-name tags' scope): each team's
    /// listed Macs, as that team's screens list them.
    public static func accountMacs(_ teams: [Team]) -> [MacDevice] {
        MacNameDisambiguation.scope(teams.map { team in
            var listed = team
            listed.macs = MacRoster(team.macs).visible
            return listed
        })
    }

    /// Every team's Macs as one list, each build once across the teams (Settings → Terminal →
    /// Terminal Size When Shared), plus any of `directory` (the account's device list, while
    /// discovery catches up) not already there.
    public static func acrossTeams(_ teams: [Team], activeTeamID _: String, including directory: [MacDevice] = []) -> [MacDevice] {
        var macs = teams.flatMap(\.macs)
        if !directory.isEmpty {
            var known = Set(macs.map(\.id))
            macs += directory.filter { known.insert($0.id).inserted }
        }
        return MacRoster(macs).visible
    }
}

extension Team {
    /// The team's Macs (``MacRoster``): what its lists, counts and pickers show.
    public var listedMacs: [MacDevice] { MacRoster(macs).visible }
}
