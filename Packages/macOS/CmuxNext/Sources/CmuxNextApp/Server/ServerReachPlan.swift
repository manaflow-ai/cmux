import CmuxNextRemote
import Foundation

/// One host of `team.hosts.list`, the fields the server reach reads.
nonisolated struct PairedServer: Sendable, Equatable {
    var host: String
    var name: String
    /// `server`, `device`, or nil from an older backend.
    var kind: String?
}

/// Which paired servers the app shows (pure; `ServerReachService` applies
/// it): every server a chief of the signed-in user is placed on
/// (`brain_place`), while the server is still in the team directory. A
/// revoked server (`server.revoke` deletes its host) drops out, so its
/// session leaves the registry. A server with no usable route is left out
/// and logged.
nonisolated struct ServerReachPlan: Sendable, Equatable {
    /// The reaches to show, one per paired host.
    var desired: [ServerReach]
    /// Placed hosts left out for want of a route (their names, for the log).
    var unroutable: [String]

    /// This Mac, when it may itself be the placed server: its short host name
    /// (pairing sends `hostname -s` as the server's default name) and the
    /// brain's daemon socket when one exists here.
    nonisolated struct LocalServer: Sendable, Equatable {
        var hostName: String
        var brainSocket: String
    }

    static func make(chiefs: [CloudChief], hosts: [PairedServer], local: LocalServer?) -> ServerReachPlan {
        let byID = Dictionary(hosts.map { ($0.host, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var desired: [ServerReach] = []
        var unroutable: [String] = []
        for chief in chiefs {
            guard let place = chief.brainPlace, let host = byID[place.host], host.kind != "device", seen.insert(place.host).inserted else { continue }
            guard let route = route(for: host, local: local),
                  let reach = try? ServerReach(hostID: host.host, installID: place.install, name: host.name, route: route)
            else {
                unroutable.append(host.name)
                continue
            }
            desired.append(reach)
        }
        return ServerReachPlan(desired: desired, unroutable: unroutable)
    }

    /// This Mac's brain socket when the server is this Mac, else SSH to the
    /// server's host name (dev-only until the overlay route exists).
    static func route(for host: PairedServer, local: LocalServer?) -> ServerReach.Route? {
        if let local, let mine = ServerReach.dnsLabel(local.hostName), ServerReach.dnsLabel(host.name) == mine {
            return .unix(local.brainSocket)
        }
        return ServerReach.brainRoute(serverName: host.name)
    }

    /// What to add and remove so the shown servers match `desired`; a server
    /// already shown keeps its session (and route) when its host stays.
    static func diff(shown: [ServerReach], desired: [ServerReach]) -> (add: [ServerReach], remove: [String]) {
        let shownHosts = Set(shown.map(\.hostID)), desiredHosts = Set(desired.map(\.hostID))
        return (desired.filter { !shownHosts.contains($0.hostID) }, shown.filter { !desiredHosts.contains($0.hostID) }.map(\.machineID))
    }

    /// The hosts of one `team.hosts.list` page and its next cursor.
    static func parseHosts(_ value: Any?) -> (hosts: [PairedServer], next: String?) {
        guard let value = value as? [String: Any], let rows = value["hosts"] as? [Any] else { return ([], nil) }
        let hosts = rows.compactMap { row -> PairedServer? in
            guard let row = row as? [String: Any], let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            return PairedServer(host: id, name: name, kind: row["kind"] as? String)
        }
        return (hosts, value["next_cursor"] as? String)
    }
}
