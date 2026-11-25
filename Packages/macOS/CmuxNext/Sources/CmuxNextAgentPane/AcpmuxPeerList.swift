import Foundation

/// The acpmux peers this Mac's daemon mirrors and whether each is reachable now: `_acpmux/peers`
/// on the daemon's socket. The daemon answers from what it holds (no peer is asked), so a slow or
/// down machine never slows the call; the deadline bounds a stuck daemon.
public nonisolated struct AcpmuxPeerList: Sendable {
    /// One peer as the daemon lists it.
    public struct Peer: Hashable, Sendable {
        /// The peer's acpmux name (`huge-blue`), the `peer` its mirrored sessions carry.
        public let name: String
        /// The daemon's link to it is up.
        public let connected: Bool
        /// The machine's resources from the link's last reading (`health` on the peer row, read
        /// every 60 s by the daemon); nil for a build that does not report them or before the first.
        public let resources: Resources?
        /// Where the daemon reaches it (`ssh://cosmic-gray`); nil when the row names none.
        public let url: String?
        /// The SF Symbol of the kind of device it is (`macmini`, `server.rack`), as the peer
        /// reported it (`health.deviceSymbol`, cmux-device-kind); nil from an older build.
        public let symbol: String?
        /// The machine's AutoCloud report (`health.autoCloud`, RFD 0172); nil from a build without it.
        public let autoCloud: AutoCloud?

        public init(name: String, connected: Bool, resources: Resources? = nil, url: String? = nil, symbol: String? = nil,
                    autoCloud: AutoCloud? = nil) {
            self.name = name
            self.connected = connected
            self.resources = resources
            self.url = url
            self.symbol = symbol
            self.autoCloud = autoCloud
        }
    }

    /// One machine's room, in whole units so a new reading that moves a number by a fraction
    /// leaves it equal (the sidebar rebuilds only on a change).
    public struct Resources: Hashable, Sendable {
        /// RAM free, in GB.
        public var ramFreeGB: Int
        /// Cores busy (the 1-minute load, at most `cores`) and cores.
        public var coresBusy: Int
        public var cores: Int
        /// Disk free where acpmux keeps its home, in GB; nil when the reading has none.
        public var diskFreeGB: Int?
        /// The machine's own budget says it is over (load, memory pressure, swap).
        public var over: Bool

        public init(ramFreeGB: Int, coresBusy: Int, cores: Int, diskFreeGB: Int?, over: Bool) {
            (self.ramFreeGB, self.coresBusy, self.cores, self.diskFreeGB, self.over) = (ramFreeGB, coresBusy, cores, diskFreeGB, over)
        }

        /// From a peer row's `health` (`_acpmux/host_health` fields); nil for an older build's
        /// `{"unsupported": true}` or a reading without free RAM, load and a core count. A value that
        /// is not a finite, non-negative number counts as missing, never as 0.
        static func parse(_ health: Any?) -> Resources? {
            guard let h = health as? [String: Any], (h["unsupported"] as? Bool) != true else { return nil }
            let pressure = h["pressure"] as? [String: Any]
            guard let ram = whole((h["ram"] as? [String: Any])?["freeBytes"], per: 1e9),
                  let load = whole((h["load"] as? [Any])?.first),
                  let cores = whole(pressure?["cores"]) ?? whole(h["cpus"]), cores > 0 else { return nil }
            return Resources(ramFreeGB: ram, coresBusy: min(cores, load), cores: cores,
                             diskFreeGB: whole((h["disk"] as? [String: Any])?["freeBytes"], per: 1e9),
                             over: (pressure?["ok"] as? Bool) == false)
        }

        /// `value / per` rounded to a whole number when it is a finite, non-negative number that fits an Int.
        static func whole(_ value: Any?, per: Double = 1) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 0 else { return nil }
            let x = (n.doubleValue / per).rounded()
            guard x.isFinite, x < Double(Int.max) else { return nil }
            return Int(x)
        }
    }

    /// A machine's AutoCloud report, `health.autoCloud` v1 (RFD 0172): whether its owner enrolled it
    /// (`_acpmux/autocloud_enroll`, turned on only by its owner's client), whether it takes work now, and the
    /// owner's policy and the machine's capabilities. Read-only everywhere else.
    public struct AutoCloud: Hashable, Sendable {
        public var enrolled: Bool
        public var accepting: Bool
        /// Nil when the report has no idle reading.
        public var ownerIdle: Bool?
        public var teams: [String]
        public var agents: [String]
        /// Local hours it may take work, `from` to `to` (may wrap midnight); nil for any hour.
        public var hours: Hours?
        public var caps: [String]

        public struct Hours: Hashable, Sendable {
            public var from: Int
            public var to: Int
            public init(from: Int, to: Int) { (self.from, self.to) = (from, to) }
        }

        public init(enrolled: Bool, accepting: Bool = false, ownerIdle: Bool? = nil, teams: [String] = [], agents: [String] = [],
                    hours: Hours? = nil, caps: [String] = []) {
            (self.enrolled, self.accepting, self.ownerIdle) = (enrolled, accepting, ownerIdle)
            (self.teams, self.agents, self.hours, self.caps) = (teams, agents, hours, caps)
        }

        /// From a peer row's `health`; nil when it has no `autoCloud` object.
        static func parse(_ health: Any?) -> AutoCloud? {
            guard let a = (health as? [String: Any])?["autoCloud"] as? [String: Any] else { return nil }
            let policy = a["policy"] as? [String: Any]
            let hours = (policy?["hours"] as? [String: Any]).flatMap { h -> Hours? in
                guard let from = Resources.whole(h["from"]), let to = Resources.whole(h["to"]) else { return nil }
                return Hours(from: from, to: to)
            }
            func strings(_ v: Any?) -> [String] { (v as? [Any] ?? []).compactMap { $0 as? String } }
            return AutoCloud(enrolled: a["enrolled"] as? Bool ?? false, accepting: a["accepting"] as? Bool ?? false,
                             ownerIdle: a["ownerIdle"] as? Bool, teams: strings(policy?["teams"]), agents: strings(policy?["agents"]),
                             hours: hours, caps: strings(a["caps"]))
        }
    }

    let socketPath: String

    public init(socketPath: String) { self.socketPath = socketPath }

    @concurrent public func peers(deadline: Duration = AcpmuxEnvironment.answerDeadline) async throws -> [Peer] {
        let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/peers", deadline: deadline)
        return Self.peers(result)
    }

    /// The peers of a `_acpmux/peers` answer (`{peers: [{name, connected, health}]}`); `healthAt`
    /// is left out, so a reading with the same numbers leaves the list equal. A `ws://`/`wss://` peer is
    /// a Cloud machine by its source (as `cmux device list` decides): it keeps the cloud, whatever its VM
    /// reports.
    static func peers(_ result: [String: Any]) -> [Peer] {
        (result["peers"] as? [[String: Any]] ?? []).compactMap { peer in
            guard let name = peer["name"] as? String, !name.isEmpty else { return nil }
            let url = (peer["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let cloud = url.map { $0.hasPrefix("ws://") || $0.hasPrefix("wss://") } ?? false
            let symbol = cloud ? nil : (peer["health"] as? [String: Any])?["deviceSymbol"] as? String
            return Peer(name: name, connected: peer["connected"] as? Bool ?? false, resources: Resources.parse(peer["health"]),
                        url: url, symbol: symbol.flatMap { $0.isEmpty ? nil : $0 }, autoCloud: AutoCloud.parse(peer["health"]))
        }
    }
}
