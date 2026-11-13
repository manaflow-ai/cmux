import Foundation

/// Decides which connectivity trouble is a major incident worth telling the cmux team about, from what
/// the phone sees: each Mac link's phase and drops, whether the app is in front, whether the phone has a
/// network, and a reachability check it asks for before it reports (PROTOCOL.md "Connectivity incidents").
///
/// Pure: events in, ``Output``s out, dates passed in. ``ConnectivityIncidentReporter`` runs it.
///
/// What it reports:
/// - **Mac unreachable**: a Mac the service says is online has not connected for
///   ``Rules/unreachableAfter`` of *qualifying* time (app active, phone on a network, no network change),
///   and a check then finds the phone's internet working. The stretch restarts whenever qualifying
///   breaks, the network changes, or the check finds the phone itself offline, so a slow but successful
///   connect, a Mac that is asleep, and the phone's own outage are never reported.
/// - **Link unstable**: ``Rules/dropsForUnstable`` drops of a live link inside ``Rules/dropWindow``,
///   not counting drops within ``Rules/settleAfter`` of the app coming to the front or the network
///   changing (links left from before are expected to die then). At most one per Mac per
///   ``Rules/unstableCooldown``.
///
/// Every reported incident gets exactly one end: `resolved` (reconnected, or stable for
/// ``Rules/stableAfter``) or `ended` with why it stopped being watched.
public struct ConnectivityIncidentDetector: Sendable {
    public struct Rules: Sendable, Equatable {
        public var unreachableAfter: TimeInterval = 30
        public var dropWindow: TimeInterval = 300
        public var dropsForUnstable = 3
        public var settleAfter: TimeInterval = 10
        public var stableAfter: TimeInterval = 600
        public var unstableCooldown: TimeInterval = 1800
        /// After a check found the phone offline, how long before checking again.
        public var recheckAfter: TimeInterval = 15
        /// How long a Mac may drop offline in the middle of an incident (its host restarting, a
        /// presence blip) before the incident ends as "the Mac went offline": coming back within it
        /// keeps the incident (and the drops counted so far), and connecting resolves it.
        public var macOfflineGrace: TimeInterval = 60
        /// A drop counts toward an unstable link only if the link is back within this.
        public var dropRecoverWithin: TimeInterval = 20

        public init() {}
    }

    /// A Mac link's state as the detector needs it (from `LinkMachine.Phase`).
    public enum LinkState: Sendable, Equatable {
        /// Dialing or waiting to redial: the link is wanted and not up.
        case trying(transport: String, reason: String?, newDial: Bool)
        case connected(transport: String)
        /// The link is not wanted now: the Mac is offline, no longer used, or the account signed out.
        case notWanted(Incident.EndReason)
    }

    public struct Incident: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Codable { case macUnreachable = "mac_unreachable", linkUnstable = "link_unstable" }
        public enum State: String, Sendable, Codable { case open, resolved, ended }
        public enum EndReason: String, Sendable, Codable {
            case appBackgrounded = "app_backgrounded"
            case networkLost = "network_lost"
            case macOffline = "mac_offline"
            case linkClosed = "link_closed"
            case signedOut = "signed_out"
            case appRelaunched = "app_relaunched"
        }

        public var id: String
        public var kind: Kind
        public var state: State
        public var endReason: EndReason?
        public var startedAt: Date
        public var observedAt: Date
        public var macID: String
        public var macName: String
        public var attempts: Int?
        public var drops: Int?
        public var lastError: String?
        public var transport: String?
        public var serviceReachable: Bool?
        public var network: String?

        public var duration: TimeInterval { max(0, observedAt.timeIntervalSince(startedAt)) }

        /// This incident in a later state at `date`.
        func with(_ state: State, at date: Date, endReason: EndReason? = nil) -> Incident {
            var next = self
            next.state = state
            next.observedAt = date
            next.endReason = endReason
            return next
        }
    }

    public enum Output: Sendable, Equatable {
        /// Check whether the phone reaches the internet and the cmux service, then call
        /// ``reachability(macID:checkID:internet:service:at:)`` with this `id`: an answer to a check
        /// that a later one replaced (the stretch restarted) is ignored.
        case check(macID: String, id: Int)
        case report(Incident)
    }

    public let rules: Rules
    public private(set) var isActive = false
    public private(set) var hasNetwork = true
    public private(set) var networkKind: String?
    private var lastWake: Date?
    private var lastNetworkChange: Date?
    private var macs: [String: Track] = [:]
    private var lastCheckID = 0
    private let makeID: @Sendable () -> String

    private struct Track: Sendable {
        var name: String
        var state: LinkState = .notWanted(.linkClosed)
        /// Start of the current qualifying stretch without a connection.
        var downSince: Date?
        var attempts = 0
        var lastError: String?
        var transport: String?
        var check: Check = .none
        var unreachable: Incident?
        var drops: [Date] = []
        /// The newest drop, kept past the window: an unstable link is stable again this long after it.
        var lastDrop: Date?
        var unstable: Incident?
        var lastUnstable: Date?
        /// When the Mac went offline while something was open or counted (see `macOfflineGrace`).
        var offlineSince: Date?
        /// A drop not counted yet: it counts once the link is back within `dropRecoverWithin`
        /// while the Mac stayed online. A drop where the Mac itself went away (quit, restart,
        /// sleep) or that turns into an unreachable stretch is not link instability.
        var pendingDrop: Date?

        enum Check: Sendable, Equatable {
            case none
            case pending(id: Int)
            case phoneOffline(Date)
        }

        var isPending: Bool {
            if case .pending = check { return true }
            return false
        }

        var isTrying: Bool {
            if case .trying = state { return true }
            return false
        }
    }

    public init(rules: Rules = Rules(), makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.rules = rules
        self.makeID = makeID
    }

    /// The incidents reported and not yet ended (persisted across launches by the reporter).
    public var openIncidents: [Incident] {
        macs.values.flatMap { [$0.unreachable, $0.unstable].compactMap { $0 } }
    }

    private var qualifies: Bool { isActive && hasNetwork }

    // MARK: Inputs

    /// The app came to the front or left it.
    public mutating func appActive(_ active: Bool, at date: Date) -> [Output] {
        guard active != isActive else { return [] }
        isActive = active
        if active {
            lastWake = date
            restartStretches(at: date)
            return []
        }
        return endAll(.appBackgrounded, at: date)
    }

    /// The phone's network: nil when it has none, else its kind (`wifi`, `cellular`, `other`). A
    /// change of network restarts every stretch (links redial onto the new path). `changed: false`
    /// is a report of the current network (the app's own path monitor): it restarts them only when
    /// the network came back or its kind changed; a new Wi-Fi of the same kind comes as `changed`.
    public mutating func network(_ kind: String?, at date: Date, changed: Bool = true) -> [Output] {
        let had = hasNetwork
        let previous = networkKind
        hasNetwork = kind != nil
        if let kind { networkKind = kind }
        guard hasNetwork else { return had ? endAll(.networkLost, at: date) : [] }
        guard changed || !had || previous != kind else { return [] }
        lastNetworkChange = date
        restartStretches(at: date)
        return []
    }

    /// A dial to the Mac failed: its reason is the incident's last error.
    public mutating func dialFailed(macID: String, reason: String) {
        macs[macID]?.lastError = reason
    }

    /// A Mac link's new state.
    public mutating func link(macID: String, name: String, _ state: LinkState, at date: Date) -> [Output] {
        var track = macs[macID] ?? Track(name: name)
        track.name = name
        let wasTrying = track.isTrying
        track.state = state
        var out: [Output] = []
        switch state {
        case .trying(let transport, let reason, let newDial):
            track.offlineSince = nil
            track.transport = transport
            if let reason { track.lastError = reason }
            if !wasTrying {
                track.downSince = qualifies ? date : nil
                track.attempts = 0
                // A check in flight (asked for an unstable link) still answers; a phone found offline
                // stays so until its recheck.
            }
            if newDial { track.attempts += 1 }
        case .connected(let transport):
            track.offlineSince = nil
            track.transport = transport
            if let drop = track.pendingDrop {
                track.pendingDrop = nil
                if date.timeIntervalSince(drop) <= rules.dropRecoverWithin {
                    track.drops.append(drop)
                    track.lastDrop = drop
                }
            }
            if let open = track.unreachable {
                var resolved = open.with(.resolved, at: date)
                resolved.attempts = track.attempts
                resolved.lastError = track.lastError
                out.append(.report(resolved))
                track.unreachable = nil
            }
            track.downSince = nil
            track.attempts = 0
            track.lastError = nil
            if case .phoneOffline = track.check { track.check = .none }
        case .notWanted(.macOffline) where track.unreachable != nil || track.unstable != nil || !track.drops.isEmpty:
            // A Mac that drops offline in the middle of trouble (its host restarting) gets the grace
            // period to come back; `evaluate` ends the incident if it does not. A check in flight is
            // about the phone's own internet and stays valid.
            track.downSince = nil
            track.pendingDrop = nil
            if track.offlineSince == nil { track.offlineSince = date }
        case .notWanted(let why):
            track.downSince = nil
            track.check = .none
            track.offlineSince = nil
            track.pendingDrop = nil
            out += Self.end(&track, why, at: date)
        }
        macs[macID] = track
        return out + evaluate(macID, at: date)
    }

    /// A live link to the Mac dropped (its stream ended or a probe went unanswered).
    public mutating func dropped(macID: String, reason: String, at date: Date) -> [Output] {
        guard var track = macs[macID], qualifies else { return [] }
        if let wake = lastWake, date.timeIntervalSince(wake) < rules.settleAfter { return [] }
        if let change = lastNetworkChange, date.timeIntervalSince(change) < rules.settleAfter { return [] }
        track.pendingDrop = date
        track.lastError = reason
        macs[macID] = track
        return evaluate(macID, at: date)
    }

    /// What the check asked for by ``Output/check(macID:id:)`` found.
    public mutating func reachability(macID: String, checkID: Int, internet: Bool, service: Bool, at date: Date) -> [Output] {
        guard var track = macs[macID], track.check == .pending(id: checkID) else { return [] }
        if !internet {
            // The phone itself is offline: not a cmux incident. Its stretch starts again from now, so
            // a Mac reported later was unreachable while the phone's internet worked.
            track.check = .phoneOffline(date)
            if track.downSince != nil { track.downSince = date }
            track.drops = []
            macs[macID] = track
            return []
        }
        track.check = .none
        var out: [Output] = []
        // One open incident per Mac: an unreachable stretch during an unstable link is part of it.
        if let since = track.downSince, track.isTrying, track.unreachable == nil, track.unstable == nil,
           date.timeIntervalSince(since) >= rules.unreachableAfter {
            let incident = Incident(id: makeID(), kind: .macUnreachable, state: .open, startedAt: since, observedAt: date,
                                    macID: macID, macName: track.name, attempts: track.attempts, lastError: track.lastError,
                                    transport: track.transport, serviceReachable: service, network: networkKind)
            track.unreachable = incident
            out.append(.report(incident))
        }
        // A link that kept dropping is reported once it is up again (the Mac is awake then; one that went
        // to sleep never reconnects). Not up yet: `evaluate` asks again when it is.
        if track.unstable == nil, track.unreachable == nil, case .connected = track.state,
           let first = unstableWindowStart(track, at: date) {
            let incident = Incident(id: makeID(), kind: .linkUnstable, state: .open, startedAt: first, observedAt: date,
                                    macID: macID, macName: track.name, drops: track.drops.count, lastError: track.lastError,
                                    transport: track.transport, serviceReachable: service, network: networkKind)
            track.unstable = incident
            track.lastUnstable = date
            out.append(.report(incident))
        }
        macs[macID] = track
        return out
    }

    /// Time passed: thresholds and stable windows are checked. Call it every few seconds while active.
    public mutating func tick(at date: Date) -> [Output] {
        macs.keys.sorted().flatMap { evaluate($0, at: date) }
    }

    // MARK: Rules

    /// Ends what is open on `track` with `why` at `date`, and forgets its drops.
    private static func end(_ track: inout Track, _ why: Incident.EndReason, at date: Date) -> [Output] {
        var out: [Output] = []
        if let open = track.unreachable {
            var ended = open.with(.ended, at: date, endReason: why)
            ended.attempts = track.attempts
            out.append(.report(ended))
            track.unreachable = nil
        }
        if let open = track.unstable {
            out.append(.report(open.with(.ended, at: date, endReason: why)))
            track.unstable = nil
        }
        track.drops = []
        track.attempts = 0
        return out
    }

    private mutating func evaluate(_ macID: String, at date: Date) -> [Output] {
        guard var track = macs[macID] else { return [] }
        var out: [Output] = []
        // Offline past the grace period: the incident ended when the Mac left.
        if let since = track.offlineSince, date.timeIntervalSince(since) >= rules.macOfflineGrace {
            track.offlineSince = nil
            out += Self.end(&track, .macOffline, at: since)
        }
        track.drops.removeAll { date.timeIntervalSince($0) > rules.dropWindow }
        if let open = track.unstable, let last = track.lastDrop ?? Optional(open.startedAt),
           date.timeIntervalSince(last) >= rules.stableAfter, case .connected = track.state {
            var resolved = open.with(.resolved, at: date)
            resolved.drops = open.drops
            out.append(.report(resolved))
            track.unstable = nil
        }
        guard qualifies else {
            macs[macID] = track
            return out
        }
        if case .phoneOffline(let at) = track.check, date.timeIntervalSince(at) >= rules.recheckAfter { track.check = .none }
        // A pending drop the link did not recover from in time is not a drop of an unstable link.
        if let drop = track.pendingDrop, date.timeIntervalSince(drop) > rules.dropRecoverWithin { track.pendingDrop = nil }
        let unreachableDue = track.isTrying && track.unreachable == nil && track.unstable == nil
            && track.downSince.map { date.timeIntervalSince($0) >= rules.unreachableAfter } == true
        let unstableDue = track.unstable == nil && track.unreachable == nil && unstableWindowStart(track, at: date) != nil
        if (unreachableDue || unstableDue), track.check == .none {
            lastCheckID += 1
            track.check = .pending(id: lastCheckID)
            out.append(.check(macID: macID, id: lastCheckID))
        }
        macs[macID] = track
        return out
    }

    private func unstableWindowStart(_ track: Track, at date: Date) -> Date? {
        let recent = track.drops.filter { date.timeIntervalSince($0) <= rules.dropWindow }
        guard recent.count >= rules.dropsForUnstable else { return nil }
        if let last = track.lastUnstable, date.timeIntervalSince(last) < rules.unstableCooldown { return nil }
        return recent.first
    }

    /// A new stretch counts its own dials: a report after a wake or a network change never carries
    /// the dials of the stretch before it.
    private mutating func restartStretches(at date: Date) {
        for id in macs.keys where macs[id]?.isTrying == true {
            macs[id]?.downSince = date
            macs[id]?.check = .none
            macs[id]?.attempts = 0
        }
    }

    private mutating func endAll(_ why: Incident.EndReason, at date: Date) -> [Output] {
        var out: [Output] = []
        for id in macs.keys.sorted() {
            guard var track = macs[id] else { continue }
            if let open = track.unreachable {
                var ended = open.with(.ended, at: date, endReason: why)
                ended.attempts = track.attempts
                out.append(.report(ended))
                track.unreachable = nil
            }
            if let open = track.unstable {
                out.append(.report(open.with(.ended, at: date, endReason: why)))
                track.unstable = nil
            }
            track.downSince = nil
            track.check = .none
            track.drops = []
            track.attempts = 0
            track.offlineSince = nil
            macs[id] = track
        }
        return out
    }
}
