public import CmuxNextRemote
public import Foundation

/// One host of `team.hosts.list`, the fields the server reach reads.
public nonisolated struct PairedServer: Sendable, Equatable {
    public var host: String
    public var name: String
    /// `server`, `device`, or nil from an older backend.
    public var kind: String?

    public init(host: String, name: String, kind: String? = nil) {
        self.host = host
        self.name = name
        self.kind = kind
    }
}

/// Which paired servers the app shows (pure; `ServerReachService` applies
/// it): every server a chief of the signed-in user is placed on
/// (`brain_place`), while the server is still in the team directory. A
/// revoked server (`server.revoke` deletes its host) drops out, so its
/// session leaves the registry. A server with no usable route is left out
/// and logged.
public nonisolated struct ServerReachPlan: Sendable, Equatable {
    /// The reaches to show, one per paired host.
    public var desired: [ServerReach]
    /// Placed hosts left out for want of a route (their names, for the log).
    public var unroutable: [String]

    public init(desired: [ServerReach], unroutable: [String]) {
        self.desired = desired
        self.unroutable = unroutable
    }

    /// This Mac, when it may itself be the placed server: its short host name
    /// (pairing sends `hostname -s` as the server's default name) and the
    /// brain's daemon socket when one exists here.
    public nonisolated struct LocalServer: Sendable, Equatable {
        /// Every name this Mac answers to: gethostname, the LocalHostName
        /// and the computer name (pairing sends `hostname -s`, which can be
        /// either, and a DHCP lease can change the first).
        public var hostNames: [String]
        public var brainSocket: String

        public init(hostNames: [String], brainSocket: String) {
            self.hostNames = hostNames
            self.brainSocket = brainSocket
        }
    }

    /// This Mac's `cmux link` (`cmux link show`, `cmux link peer list`):
    /// its socket while it runs and the installs it has paired peers for.
    public nonisolated struct LinkPeers: Sendable, Equatable {
        /// The live link's socket; nil while the link is not running.
        public var socket: String?
        public var installs: Set<String>
        /// The link's pairing file (`cmux link show` `peers_file`), watched
        /// so a peer change re-resolves routes; nil from an older CLI.
        public var peersFile: String?
        /// This Mac's own install id (`cmux link show` `install`). On a
        /// server it is the server's install, the one `brain_place` names.
        public var install: String?

        public init(socket: String? = nil, installs: Set<String>, peersFile: String? = nil, install: String? = nil) {
            self.socket = socket
            self.installs = installs
            self.peersFile = peersFile
            self.install = install
        }

        /// The link's registration (`link.json` in the parent of the link
        /// state directory): written when the link starts, removed when it
        /// stops, so watching it notices a link that starts after a read.
        public var registrationFile: String? {
            guard let peersFile else { return nil }
            let stateDir = URL(fileURLWithPath: peersFile).deletingLastPathComponent()
            return stateDir.deletingLastPathComponent().appendingPathComponent("link.json").path
        }

        /// The files whose change re-reads the link.
        public var watchedFiles: [String] { [peersFile, registrationFile].compactMap { $0 } }
    }

    public static func make(chiefs: [CloudChief], hosts: [PairedServer], local: LocalServer?, link: LinkPeers? = nil) -> ServerReachPlan {
        let byID = Dictionary(hosts.map { ($0.host, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var desired: [ServerReach] = []
        var unroutable: [String] = []
        for chief in chiefs {
            guard let place = chief.brainPlace, let host = byID[place.host], host.kind != "device", seen.insert(place.host).inserted else { continue }
            guard let route = route(for: host, install: place.install, local: local, link: link),
                  let reach = try? ServerReach(hostID: host.host, installID: place.install, name: host.name, route: route)
            else {
                unroutable.append(host.name)
                continue
            }
            desired.append(reach)
        }
        return ServerReachPlan(desired: desired, unroutable: unroutable)
    }

    /// This Mac's brain socket when the server is this Mac; else the overlay
    /// when this Mac's link has the server's install as a paired peer; else
    /// SSH to the server's host name (dev-only).
    public static func route(for host: PairedServer, install: String? = nil, local: LocalServer?, link: LinkPeers? = nil) -> ServerReach.Route? {
        if let local, isThisMac(host, install: install, local: local, link: link) {
            return .unix(local.brainSocket)
        }
        if let link, let socket = link.socket, let install, link.installs.contains(install) {
            return .overlay(linkSocket: socket)
        }
        return ServerReach.brainRoute(serverName: host.name)
    }

    /// Whether the placed server is this Mac: by install id when this Mac's
    /// link names one (a server paired under another name still matches,
    /// and another Mac with the same name never does); by host name only
    /// when this Mac has no link install (bead cx-ill).
    public static func isThisMac(_ host: PairedServer, install: String?, local: LocalServer, link: LinkPeers?) -> Bool {
        if let mine = link?.install { return mine == install }
        guard let theirs = ServerReach.dnsLabel(host.name) else { return false }
        return local.hostNames.contains(where: { ServerReach.dnsLabel($0) == theirs })
    }

    /// `cmux link show` and `cmux link peer list` JSON: the link, running or
    /// not (a stopped link still names its pairing file and install), or nil
    /// when `show` is not an object.
    public static func linkPeers(show: Data, peers: Data?) -> LinkPeers? {
        guard let object = (try? JSONSerialization.jsonObject(with: show)) as? [String: Any] else { return nil }
        let install = (object["install"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return LinkPeers(socket: parseLinkShow(show), installs: peers.map(parsePeerList) ?? [],
                         peersFile: parseLinkPeersFile(show), install: install)
    }

    /// The default link's config file (`cmux link init` writes it):
    /// `<CMUX_TUI_STATE_DIR or ~/Library/Application Support/cmux-tui/sessions>/link/config.json`.
    /// Its watch sits on the nearest existing directory until it appears.
    public static func defaultLinkSetupFile(environment: [String: String], home: String) -> String {
        let state = environment["CMUX_TUI_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/Library/Application Support/cmux-tui/sessions"
        return URL(fileURLWithPath: state).appendingPathComponent("link/config.json").path
    }

    /// `cmux link show` JSON: the live link's socket, or nil when it is not running.
    public static func parseLinkShow(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["running"] as? Bool == true, let socket = object["socket"] as? String, socket.hasPrefix("/") else { return nil }
        return socket
    }

    /// `cmux link peer list` JSON: the paired installs.
    public static func parsePeerList(_ data: Data) -> Set<String> {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let peers = object?["peers"] as? [[String: Any]] ?? []
        return Set(peers.compactMap { $0["install"] as? String })
    }

    /// Reuse a session only while its paired installation and route are unchanged.
    /// A host reinstalled behind the same link socket is a replacement owner.
    public static func diff(shown: [ServerReach], desired: [ServerReach]) -> (add: [ServerReach], remove: [String], reroute: [ServerReach]) {
        let shownByHost = Dictionary(shown.map { ($0.hostID, $0) }, uniquingKeysWith: { first, _ in first })
        let desiredHosts = Set(desired.map(\.hostID))
        let add = desired.filter { shownByHost[$0.hostID] == nil }
        let reroute = desired.filter { reach in shownByHost[reach.hostID].map { $0.installID != reach.installID || $0.route != reach.route } ?? false }
        return (add, shown.filter { !desiredHosts.contains($0.hostID) }.map(\.machineID), reroute)
    }

    /// `cmux link show` JSON: the link's pairing file, when the CLI names it.
    public static func parseLinkPeersFile(_ data: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let file = object?["peers_file"] as? String, file.hasPrefix("/") else { return nil }
        return file
    }

    public nonisolated enum ReadError: Error, Equatable {
        /// A reply without the expected shape: never read as "no servers".
        case malformed(String)
        case tooManyHosts
    }

    /// The chiefs of a `chief.list` value; throws on a reply without `chiefs`.
    public static func parseChiefs(_ value: Any?) throws -> [CloudChief] {
        guard let value = value as? [String: Any], let chiefs = value["chiefs"] as? [Any] else { throw ReadError.malformed("chief.list") }
        return chiefs.compactMap(CloudChief.parse)
    }

    /// The hosts of one `team.hosts.list` page and its next cursor; throws
    /// on a reply without `hosts`.
    public static func parseHosts(_ value: Any?) throws -> (hosts: [PairedServer], next: String?) {
        guard let value = value as? [String: Any], let rows = value["hosts"] as? [Any] else { throw ReadError.malformed("team.hosts.list") }
        let hosts = rows.compactMap { row -> PairedServer? in
            guard let row = row as? [String: Any], let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            return PairedServer(host: id, name: name, kind: row["kind"] as? String)
        }
        return (hosts, value["next_cursor"] as? String)
    }
}
