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

        public init(name: String, connected: Bool, resources: Resources? = nil) {
            self.name = name
            self.connected = connected
            self.resources = resources
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
        /// What the machine's health loop found wrong and could not fix, in its order (`problems` on the
        /// reading, from `/run/cmux/machine-health.json`); empty when it reports none or runs no loop.
        public var problems: [Problem]

        public init(ramFreeGB: Int, coresBusy: Int, cores: Int, diskFreeGB: Int?, over: Bool, problems: [Problem] = []) {
            (self.ramFreeGB, self.coresBusy, self.cores, self.diskFreeGB, self.over) = (ramFreeGB, coresBusy, cores, diskFreeGB, over)
            self.problems = problems
        }

        /// One thing the machine's health loop found wrong. Only what the row shows: `since` is left
        /// out, so the value stays equal while the same problem lasts.
        public struct Problem: Hashable, Sendable {
            /// The check that failed: `dns`, `disk`, `ram`, `acpmux`, `peer` or `loop` (the loop itself
            /// stopped); another name is still a problem, shown without its own word.
            public var check: String
            /// The machine's own words, one line (`DNS: github.com does not resolve`).
            public var detail: String

            public init(check: String, detail: String) {
                (self.check, self.detail) = (check, detail)
            }

            /// The most a reading carries (acpmux caps it the same way).
            static let maxCount = 8
            static let maxDetail = 200

            /// The well-formed entries of a reading's `problems`: an entry without a non-empty `check`
            /// and `detail` string is skipped, never shown made up.
            static func parse(_ value: Any?) -> [Problem] {
                guard let list = value as? [Any] else { return [] }
                return Array(list.lazy.compactMap { entry -> Problem? in
                    guard let e = entry as? [String: Any], let check = e["check"] as? String, let detail = e["detail"] as? String
                    else { return nil }
                    let (c, d) = (check.trimmingCharacters(in: .whitespacesAndNewlines), Self.oneLine(detail))
                    return c.isEmpty || d.isEmpty ? nil : Problem(check: c.lowercased(), detail: d)
                }.prefix(maxCount))
            }

            /// `text` on one line (a character with a control, line or paragraph separator scalar as a
            /// space; a joiner inside an emoji stays), trimmed, then at most `maxDetail` whole characters,
            /// so an emoji or accented letter is never cut in half.
            static func oneLine(_ text: String) -> String {
                let breaks: Set<Unicode.GeneralCategory> = [.control, .lineSeparator, .paragraphSeparator]
                let flat = String(text.map { c in c.unicodeScalars.contains { breaks.contains($0.properties.generalCategory) } ? " " : c })
                return String(flat.trimmingCharacters(in: .whitespaces).prefix(maxDetail)).trimmingCharacters(in: .whitespaces)
            }
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
                             over: (pressure?["ok"] as? Bool) == false, problems: Problem.parse(h["problems"]))
        }

        /// `value / per` rounded to a whole number when it is a finite, non-negative number that fits an Int.
        static func whole(_ value: Any?, per: Double = 1) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue >= 0 else { return nil }
            let x = (n.doubleValue / per).rounded()
            guard x.isFinite, x < Double(Int.max) else { return nil }
            return Int(x)
        }
    }

    let socketPath: String

    public init(socketPath: String) { self.socketPath = socketPath }

    @concurrent public func peers(deadline: Duration = .seconds(2)) async throws -> [Peer] {
        let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/peers", deadline: deadline)
        return Self.peers(result)
    }

    /// The peers of a `_acpmux/peers` answer (`{peers: [{name, connected, health}]}`); `healthAt`
    /// is left out, so a reading with the same numbers leaves the list equal.
    static func peers(_ result: [String: Any]) -> [Peer] {
        (result["peers"] as? [[String: Any]] ?? []).compactMap { peer in
            guard let name = peer["name"] as? String, !name.isEmpty else { return nil }
            return Peer(name: name, connected: peer["connected"] as? Bool ?? false, resources: Resources.parse(peer["health"]))
        }
    }
}
