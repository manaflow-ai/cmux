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
        /// The selected Mac's presence is offline; no dial until it returns.
        case macOffline
        case connecting(TransportKind, attempt: Int)
        case connected(TransportKind, LinkPathKind, rttMillis: UInt32?)
        /// The last dial or link failed; the next dial is scheduled.
        case waiting(TransportKind, attempt: Int, reason: String, retryIn: Duration)
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

    public init(transport: TransportKind, relayOnly: Bool = false, blockUDP: Bool = false) {
        self.transport = transport
        self.relayOnly = relayOnly
        self.blockUDP = blockUDP
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .background:
            isBackgrounded = true
            return []
        case .resume:
            let wasBackgrounded = isBackgrounded
            isBackgrounded = false
            if wasBackgrounded, isActive {
                return dial(attempt: 1, closing: true)
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
                return reset(to: .macOffline)
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
            guard gen == generation, case .connecting = phase else { return [] }
            phase = .connected(transport, path, rttMillis: nil)
            return []
        case .dialFailed(let gen, let reason):
            guard gen == generation, case .connecting(_, let attempt) = phase else { return [] }
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
            // The Mac is offline: nothing to dial until presence brings it back.
            if target?.isOnline == false { return reset(to: .macOffline) }
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
            default: return []
            }
        case .retryDue(let gen):
            guard gen == generation, case .waiting(_, let attempt, _, _) = phase else { return [] }
            return dial(attempt: attempt + 1, closing: false)
        case .foreground:
            switch phase {
            case .waiting(_, let attempt, _, _): return dial(attempt: attempt + 1, closing: false)
            case .connected: return [.probe(generation: generation)]
            default: return []
            }
        }
    }

    private var isActive: Bool {
        switch phase {
        case .connecting, .connected, .waiting: true
        case .idle, .macOffline: false
        }
    }

    private mutating func reset(to next: Phase) -> [Effect] {
        let wasActive = isActive
        generation += 1
        media = .off
        phase = next
        return wasActive ? [.close] : []
    }

    private mutating func dial(attempt: Int, closing: Bool) -> [Effect] {
        guard let target else { return [] }
        let wasActive = isActive
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
        case .macOffline: true
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
