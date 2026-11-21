import struct CmuxMobileModel.MacDevice
import CmuxMobileTransport
import Foundation

/// The connection to the selected Mac as a pure state machine: events in,
/// effects out. `LinkController` runs the effects (dial, close, timers);
/// tests drive the machine directly.
///
/// A generation number tags every dial and timer, so a late result from a
/// dial the machine already abandoned (transport switch, Mac change) is
/// ignored.
public struct LinkMachine: Sendable {
    /// The Mac to keep a link to.
    public struct Target: Equatable, Sendable {
        public var macID: String
        public var name: String
        public var isOnline: Bool

        public init(macID: String, name: String, isOnline: Bool) {
            self.macID = macID
            self.name = name
            self.isOnline = isOnline
        }
    }

    public enum Phase: Equatable, Sendable {
        /// No Mac selected.
        case idle
        /// The selected Mac's presence is offline. The phone still tries it
        /// quietly (``LinkMachine/offlineDial``): presence can be stale.
        case macOffline
        case connecting(TransportKind, attempt: Int)
        case connected(TransportKind, LinkPathKind, rttMillis: UInt32?)
        /// The last dial or link failed; the next dial is scheduled.
        case waiting(TransportKind, attempt: Int, reason: String, retryIn: Duration)
        /// The account's session was revoked: the cmux service refused even a
        /// freshly minted token. Nothing redials (a retry cannot succeed); the
        /// person is asked to sign in again. Nothing leaves it, an untarget
        /// (an idle link closed) and a retarget included: sign-out ends this
        /// machine's controller (`LiveCoordinator.stop` closes every session),
        /// and the next sign-in starts new ones.
        case signedOut
    }

    public enum Event: Equatable, Sendable {
        case target(Target?)
        case transport(TransportKind)
        /// Debug relay-only mode on or off; a change redials.
        case relayOnly(Bool)
        /// Debug UDP-blocked mode on or off; a change redials.
        case blockUDP(Bool)
        case dialSucceeded(generation: Int, path: LinkPathKind)
        case dialFailed(generation: Int, reason: String)
        /// The link reported a new path or RTT.
        case linkUpdated(generation: Int, path: LinkPathKind, rttMillis: UInt32?)
        /// The WebRTC media session beside a WireGuard link changed.
        case mediaUpdated(generation: Int, VideoMediaState)
        case linkDropped(generation: Int, reason: String)
        case retryDue(generation: Int)
        /// The app came to the foreground (or the network came back).
        case foreground
        /// The scene actually entered the background; links may go stale
        /// while iOS suspends the process. Inactive scenes do not count.
        case background
        /// The scene became active. Replace any link kept across suspension.
        case resume
        case probeFailed(generation: Int, reason: String)
        /// A presence frame says the target Mac's signaling socket is up
        /// (again): its host may have restarted under a live link, whose
        /// peer is then gone. Probe now, not at the next heartbeat.
        case macSignaled
        /// The phone's network changed or came back (the path monitor). A
        /// dial in flight started on the old path, and its offer may have
        /// gone out on a socket that died with it: start it again on the new
        /// one, as for `macSignaled`. A live link roams in place (the dialer's
        /// `networkChanged`), so it is left alone.
        case networkChanged
        /// The dial of `generation` failed because the account's session was
        /// revoked (``Phase/signedOut``).
        case signedOut(generation: Int)
    }

    public enum Effect: Equatable, Sendable {
        case dial(generation: Int, macID: String, transport: TransportKind)
        /// Close the current link (if any) and drop its channels.
        case close
        case scheduleRetry(generation: Int, after: Duration)
        /// Ping the live link; a failure comes back as `probeFailed`.
        case probe(generation: Int)
        /// Ping the live link with a short timeout (presence changed under it).
        case quickProbe(generation: Int)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var target: Target?
    public private(set) var transport: TransportKind
    /// Debug "simulate distant network": dials skip every direct path.
    public private(set) var relayOnly: Bool
    /// Debug "simulate a network that blocks UDP": WireGuard rides TURN over TLS.
    public private(set) var blockUDP: Bool
    public private(set) var generation = 0
    public private(set) var isBackgrounded = false
    /// The current link's WebRTC media session (browser video), `off` between links.
    public private(set) var media: VideoMediaState = .off
    /// Retry delays in seconds after the silent retries; the last one repeats.
    public var backoff: [Int] = [1, 2, 4, 8, 15, 30]
    /// Failed dials retried at once, before any failure shows.
    public static let silentRetries = 1
    /// Delays in seconds between the quiet dials to a Mac that presence calls
    /// offline (``Phase/macOffline``): one at once, then one after each delay. Presence can be wrong or late (a stale warm-start snapshot, a
    /// signaling socket that reset on a loaded Mac) while the Mac answers a dial,
    /// so the phone tries the Mac itself instead of waiting for presence (the
    /// user, 2026-11-21: "just connect ... from iOS to Mac. Like just do it well").
    public var offlineBackoff: [Int] = [3, 10, 30]
    /// The quiet dial in ``Phase/macOffline``: its attempt number while one is in
    /// flight, nil otherwise. The phase stays `macOffline` (no "Reconnecting…", no
    /// incident) until the dial succeeds.
    public private(set) var offlineDial: Int?
    /// The attempt the next quiet dial in ``Phase/macOffline`` makes.
    private var offlineAttempts = 0

    /// A dial is in flight: a normal one (``Phase/connecting``) or a quiet one
    /// to a Mac presence calls offline. `LinkController` adopts a link only then.
    public var isDialing: Bool {
        if case .connecting = phase { return true }
        return offlineDial != nil
    }

    public init(transport: TransportKind, relayOnly: Bool = false, blockUDP: Bool = false) {
        self.transport = transport
        self.relayOnly = relayOnly
        self.blockUDP = blockUDP
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        if case .signedOut = phase {
            // Terminal: no dial, probe or retry. A target change (`applyLinks`
            // closing an idle link, then opening it again) is recorded, never
            // dialed: the same refused session cannot connect.
            if case .target(let next) = event { target = next }
            return []
        }
        switch event {
        case .signedOut(let gen):
            guard gen == generation else { return [] }
            return reset(to: .signedOut)
        case .background:
            isBackgrounded = true
            return []
        case .resume:
            let wasBackgrounded = isBackgrounded
            isBackgrounded = false
            if wasBackgrounded, isActive {
                return dial(attempt: 1, closing: true)
            }
            // A quiet dial left from before the background may sit on a dead
            // path: start it over, as `.connecting` does above.
            if wasBackgrounded, phase == .macOffline, offlineDial != nil {
                return [.close] + offlineDialNow(restarting: true)
            }
            return handle(.foreground)
        case .target(let next):
            let sameMac = next?.macID == target?.macID
            target = next
            guard let next else { return reset(to: .idle) }
            if !next.isOnline {
                // Presence is signaling, the link is peer to peer: a reset of
                // the Mac's signaling socket (a Worker deploy) says "offline"
                // for a moment while the link is fine. Keep it and probe it;
                // a dead one fails the probe (termfix-r13 D2a, T-LIFE-17).
                if sameMac, case .connected = phase { return [.quickProbe(generation: generation)] }
                // Already offline for this Mac: its quiet dials go on (`applyLinks`
                // sends the target again on every list or focus change).
                if sameMac, phase == .macOffline { return [] }
                return goOffline()
            }
            if sameMac, isActive { return [] }
            return dial(attempt: 1, closing: true)
        case .transport(let next):
            guard next != transport else { return [] }
            transport = next
            guard let target, target.isOnline else { return [] }
            return dial(attempt: 1, closing: true)
        case .relayOnly(let next):
            guard next != relayOnly else { return [] }
            relayOnly = next
            guard let target, target.isOnline else { return [] }
            return dial(attempt: 1, closing: true)
        case .blockUDP(let next):
            guard next != blockUDP else { return [] }
            blockUDP = next
            // WebRTC ignores it: no redial (the next WireGuard dial uses it).
            guard transport == .wireGuard, let target, target.isOnline else { return [] }
            return dial(attempt: 1, closing: true)
        case .dialSucceeded(let gen, let path):
            guard gen == generation, isDialing else { return [] }
            // A quiet dial to a Mac presence called offline got through: presence was wrong.
            offlineDial = nil
            offlineAttempts = 0
            phase = .connected(transport, path, rttMillis: nil)
            return []
        case .dialFailed(let gen, let reason):
            guard gen == generation else { return [] }
            if phase == .macOffline, offlineDial != nil {
                // The Mac did not answer either: it stays offline, and the next quiet dial waits.
                offlineDial = nil
                return scheduleOfflineDial()
            }
            guard case .connecting(_, let attempt) = phase else { return [] }
            // The first failure retries at once and says nothing: most are a
            // signaling socket the service just reset (a deploy resets them
            // all) or a stale warm socket, and the next dial opens a new one.
            if attempt <= Self.silentRetries { return dial(attempt: attempt + 1, closing: false) }
            return wait(attempt: attempt, reason: reason)
        case .linkUpdated(let gen, let path, let rtt):
            guard gen == generation, case .connected(let kind, _, let oldRTT) = phase else { return [] }
            phase = .connected(kind, path, rttMillis: rtt ?? oldRTT)
            return []
        case .mediaUpdated(let gen, let state):
            guard gen == generation, phase.isConnected else { return [] }
            media = state
            return []
        case .linkDropped(let gen, _), .probeFailed(let gen, _):
            guard gen == generation, case .connected = phase else { return [] }
            // Presence says the Mac is offline: say so, and try it quietly (presence can be late).
            if target?.isOnline == false { return goOffline() }
            // Redial at once; a failure then takes the usual retry path.
            return [.close] + dial(attempt: 1, closing: false)
        case .macSignaled:
            switch phase {
            case .connected: return [.quickProbe(generation: generation)]
            // The Mac just came back: dial now, not at the end of the backoff.
            case .waiting(_, let attempt, _, _): return dial(attempt: attempt + 1, closing: false)
            // A dial in flight sent its offer to a host that was down or
            // restarting (a cmux-mobile-host kill: back on signaling in 1.6 s, the
            // offer unanswered until the 25 s dial timeout). Presence frames
            // come only when a Mac's socket connects, closes or is renamed, so
            // this restarts a dial only when the host is newly reachable.
            case .connecting(_, let attempt): return dial(attempt: attempt, closing: false)
            case .macOffline: return offlineDialNow()
            default: return []
            }
        case .networkChanged:
            switch phase {
            case .waiting(_, let attempt, _, _): return dial(attempt: attempt + 1, closing: false)
            // Without this a retry dial on the dead path waited out its whole
            // dial timeout (25 s) and then a backoff step after the network
            // was back (iOS reliability matrix, network_back_during_inflight_dial).
            case .connecting(_, let attempt): return dial(attempt: attempt, closing: false)
            // Same for a quiet dial in flight on the dead path.
            case .macOffline: return offlineDialNow(restarting: true)
            default: return []
            }
        case .retryDue(let gen):
            guard gen == generation else { return [] }
            if phase == .macOffline {
                // In the background nothing dials; the next foreground does.
                guard offlineDial == nil, !isBackgrounded else { return [] }
                return quietDial()
            }
            guard case .waiting(_, let attempt, _, _) = phase else { return [] }
            return dial(attempt: attempt + 1, closing: false)
        case .foreground:
            switch phase {
            case .waiting(_, let attempt, _, _): return dial(attempt: attempt + 1, closing: false)
            case .connected: return [.probe(generation: generation)]
            // Opening the app is when presence is most likely stale: try the Mac now.
            case .macOffline: return offlineDialNow()
            default: return []
            }
        }
    }

    private var isActive: Bool {
        switch phase {
        case .connecting, .connected, .waiting: true
        case .idle, .macOffline, .signedOut: false
        }
    }

    private mutating func reset(to next: Phase) -> [Effect] {
        // A quiet dial in flight or waiting is dropped with the link.
        let wasActive = isActive || offlineDial != nil
        generation += 1
        media = .off
        phase = next
        offlineDial = nil
        offlineAttempts = 0
        return wasActive ? [.close] : []
    }

    /// Presence says the target Mac is offline: the phase says so, and a quiet
    /// dial tries it at once (presence can be stale while the Mac answers).
    private mutating func goOffline() -> [Effect] {
        reset(to: .macOffline) + (isBackgrounded ? [] : quietDial())
    }

    /// A quiet dial now (the app came forward, the network or the Mac's
    /// signaling changed), unless one is in flight and `restarting` is false
    /// (a network change or a resume restarts it); its backoff starts over.
    private mutating func offlineDialNow(restarting: Bool = false) -> [Effect] {
        guard restarting || offlineDial == nil, !isBackgrounded else { return [] }
        offlineAttempts = 0
        return quietDial()
    }

    /// Dials the Mac presence calls offline, keeping the phase `macOffline`.
    private mutating func quietDial() -> [Effect] {
        guard let target, phase == .macOffline else { return [] }
        generation += 1
        media = .off
        offlineAttempts += 1
        offlineDial = offlineAttempts
        return [.dial(generation: generation, macID: target.macID, transport: transport)]
    }

    /// The next quiet dial after `offlineBackoff`, on this generation. After the
    /// last delay nothing more is scheduled: a Mac that is really off (one last
    /// seen months ago is listed too) costs a few dials per app open, not one
    /// every half minute. The app coming forward, a network change, the Mac's
    /// signaling coming back or Retry start the series again.
    private mutating func scheduleOfflineDial() -> [Effect] {
        guard !isBackgrounded, offlineAttempts <= offlineBackoff.count else { return [] }
        let seconds = offlineBackoff[max(offlineAttempts - 1, 0)]
        return [.scheduleRetry(generation: generation, after: .seconds(seconds))]
    }

    private mutating func dial(attempt: Int, closing: Bool) -> [Effect] {
        guard let target else { return [] }
        let wasActive = isActive || offlineDial != nil
        offlineDial = nil
        offlineAttempts = 0
        generation += 1
        media = .off
        phase = .connecting(transport, attempt: attempt)
        let effects: [Effect] = [.dial(generation: generation, macID: target.macID, transport: transport)]
        return closing && wasActive ? [.close] + effects : effects
    }

    private mutating func wait(attempt: Int, reason: String) -> [Effect] {
        generation += 1
        media = .off
        let seconds = backoff[min(max(attempt - 1 - Self.silentRetries, 0), backoff.count - 1)]
        phase = .waiting(transport, attempt: attempt, reason: reason, retryIn: .seconds(seconds))
        return [.scheduleRetry(generation: generation, after: .seconds(seconds))]
    }
}

extension LinkMachine.Phase {
    /// How long a link may stay down (connecting or retrying) before the
    /// terminals say the Mac is offline (T-LIFE-13: within 5 s).
    public static let offlineAfter: Duration = .seconds(4)

    /// Whether terminal tabs show their Mac as offline (last frame kept,
    /// no "Reattaching…" spinner) after the link has been down this long.
    /// A first dial still under way is not called offline: only one that
    /// failed (the Mac did not answer) or presence says so.
    public func showsTerminalsOffline(notConnectedFor down: Duration) -> Bool {
        switch self {
        case .idle, .connected: false
        case .macOffline, .signedOut: true
        case .waiting(_, _, let reason, _) where reason == LinkController.reason(LinkError(code: "offline", message: "")): true
        // A first dial gets longer (a slow connect is not a dead Mac), but
        // never unbounded: one after a lost link can wait out its whole dial
        // timeout (r13 review).
        case .connecting(_, let attempt) where attempt <= 1: down >= Self.offlineAfter * 2
        case .connecting, .waiting: down >= Self.offlineAfter
        }
    }

    /// One short line for the Mac's section header and Settings. Transport,
    /// path, latency, and daemon failures remain available to diagnostics;
    /// the normal UI says what the person can do next.
    public func statusLine(macName _: String, media _: VideoMediaState = .off) -> String? {
        switch self {
        case .idle: nil
        case .macOffline: "Offline"
        case .signedOut: "Signed out"
        case .connecting: "Reconnecting…"
        case .connected: "Connected"
        case .waiting(_, _, let reason, _):
            reason == LinkController.reason(LinkError(code: "offline", message: ""))
                ? "Offline"
                : "Reconnecting…"
        }
    }

    /// Technical detail for the explicit diagnostics disclosure only.
    public func diagnosticLine(macName: String, media: VideoMediaState = .off) -> String? {
        switch self {
        case .idle: nil
        case .macOffline: "\(macName) is offline"
        case .signedOut: "This device was signed out (the cmux service refused a fresh token)"
        case .connecting(let transport, let attempt):
            "\(transport.displayName) connecting · attempt \(attempt)"
        case .connected(let transport, let path, let rtt):
            ["Connected", "\(transport.displayName) \(path.displayName)", media.statusLabel, rtt.map { "\($0) ms" }]
                .compactMap { $0 }.joined(separator: " · ")
        case .waiting(let transport, _, let reason, let retryIn):
            "\(transport.displayName) failed: \(reason) · retrying in \(retryIn.components.seconds) s"
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

extension LinkMachine {
    /// A terminal is offline when its own Mac is: the linked Mac by the
    /// link's phase, any other Mac at once (the link moved to another Mac on
    /// the account, so this one cannot reattach; live rig r13: a quit Mac's
    /// tab said "Reattaching…" for 60 s while the link served the account's
    /// other Mac).
    public static func terminalOffline(macID: String?, linkedMacID: String?, linkOffline: Bool) -> Bool {
        guard let macID, macID != linkedMacID else { return linkOffline }
        return true
    }
}

extension LinkPathKind {
    public var displayName: String {
        switch self {
        case .direct: "direct"
        case .turn: "relay (TURN)"
        case .turnTLS: "relay (TURN over TLS)"
        case .noPath: "no path"
        }
    }
}

extension LinkMachine {
    /// The Mac to dial: the remembered one, else the one already linked, else
    /// any, each online first. When the linked Mac goes offline and no other
    /// is online, the target stays on it: "mobile mini is offline", then a redial
    /// when it is back. (Falling back to the list's first Mac named a Mac
    /// last seen hours ago in the offline banner.)
    public static func target(in macs: [MacDevice], remembered: String?, current: String?) -> MacDevice? {
        macs.first { $0.id == remembered && $0.isOnline }
            ?? macs.first { $0.id == current && $0.isOnline }
            ?? macs.first(where: \.isOnline)
            ?? macs.first { $0.id == remembered }
            ?? macs.first { $0.id == current }
            ?? macs.first
    }
}
