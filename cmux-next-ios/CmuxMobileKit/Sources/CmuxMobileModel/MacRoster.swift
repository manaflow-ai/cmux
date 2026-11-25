import Foundation

/// Which of the account's Macs the Mac filter, Workspaces, Home and the links
/// list: one per computer.
///
/// Every cmux build registers its own device (its own id, identity key and
/// paired phones), so one computer running a nightly and a dev build, or one
/// that kept a deleted build's record, is on the account more than once. Each
/// Mac says which computer it runs on (`MacDevice.machineID`, PROTOCOL.md
/// "Devices"); the records of one owner with one machine id are one computer,
/// listed once by its most recently active build. The others are that Mac's
/// other builds (`otherBuilds`), still listed in Settings → Devices.
///
/// A name is never an identity: several Macs can share one (they stay apart,
/// with the `MacNameDisambiguation` tag), and a Mac that sent no machine id is
/// never folded into another.
public struct MacRoster: Equatable, Sendable {
    /// Listed: one build per computer, in the given order.
    public let visible: [MacDevice]
    /// The other builds on a listed Mac's computer, by the listed Mac's id,
    /// most recently active first.
    public let otherBuilds: [String: [MacDevice]]

    public init(_ macs: [MacDevice]) {
        var groups: [String: [MacDevice]] = [:]
        var order: [String] = []
        for mac in macs {
            let key = Self.computer(of: mac)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(mac)
        }
        var listed = Set<String>()
        var others: [String: [MacDevice]] = [:]
        for key in order {
            let ranked = (groups[key] ?? []).sorted(by: Self.moreActive)
            guard let first = ranked.first else { continue }
            listed.insert(first.id)
            var seen: Set<String> = [first.id]
            let rest = ranked.filter { seen.insert($0.id).inserted }
            if !rest.isEmpty { others[first.id] = rest }
        }
        visible = macs.filter { listed.contains($0.id) }
        otherBuilds = others
    }

    /// Every Mac that is another build of a listed one.
    public var hiddenIDs: Set<String> { Set(otherBuilds.values.flatMap { $0.map(\.id) }) }

    /// The account's listed Macs (the same-name tags' scope): each team's
    /// listed Macs, as that team's screens list them.
    public static func accountMacs(_ teams: [Team]) -> [MacDevice] {
        MacNameDisambiguation.scope(teams.map { team in
            var listed = team
            listed.macs = MacRoster(team.macs).visible
            return listed
        })
    }

    /// The computer a Mac record belongs to: its owner and machine id, or the
    /// record alone when it never said which computer it is.
    static func computer(of mac: MacDevice) -> String {
        guard let machine = mac.machineID, !machine.isEmpty else { return "device\u{0}\(mac.id)" }
        return "machine\u{0}\(mac.ownerUserID ?? "")\u{0}\(machine)"
    }

    /// Online first; then the one seen last; then the id, so two online builds
    /// keep one order however their sockets reconnect.
    static func moreActive(_ a: MacDevice, _ b: MacDevice) -> Bool {
        if a.isOnline != b.isOnline { return a.isOnline }
        if !a.isOnline {
            let seenA = a.lastSeenAt ?? .distantPast
            let seenB = b.lastSeenAt ?? .distantPast
            if seenA != seenB { return seenA > seenB }
        }
        return a.id < b.id
    }
}

extension Team {
    /// The team's Macs one per computer (``MacRoster``): what its lists, counts and pickers show.
    public var listedMacs: [MacDevice] { MacRoster(macs).visible }
}
