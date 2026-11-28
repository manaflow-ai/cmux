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
        /// The selected Mac's presence is offline, or a dial made while it said
        /// so failed; no dial until presence brings it back or a surface of
        /// the Mac opens (``Event/open``).
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
        /// The dial of `generation` found no way to the Mac on this network
        /// (PROTOCOL.md "When no path works"); its `dialFailed` follows.
        case networkBlocked(generation: Int, NetworkBlock)
        /// The link reported a new path or RTT.
        case linkUpdated(generation: Int, path: LinkPathKind, rttMillis: UInt32?)
        /// The WebRTC media session beside a WireGuard link changed.
        case mediaUpdated(generation: Int, VideoMediaState)
        case linkDropped(generation: Int, reason: String)
        case retryDue(generation: Int)
        /// The app came to the foreground (or the network came back).
        case foreground
        /// A surface of this Mac opened on screen (a terminal tab, a browser
        /// tab): try the link now, whatever presence last said. A cached or
        /// stale "offline" is never shown without a dial behind it (Leo,
        /// 2026-11-21: "it just says like, you know, cosmic gray is offline
        /// or something. But like clearly it wasn't").
        case open
        /// The scene actually entered the background; links may go stale
        /// while iOS suspends the process. Inactive scenes do not count.
        case background
        /// The scene became active after an unknown time away. A parked link resumes;
        /// any other link kept across suspension is replaced.
        case resume
        /// The scene became active `after` this long in the background. A parked link
        /// resumes. Otherwise, under ``shortSuspend`` the live link is kept and probed,
        /// never closed: an app switch of a second leaves every channel, attach and chat
        /// in place (Leo, 2026-11-22). Longer, the link stays beside the redial (make
        /// before break).
        case resumed(after: Duration)
        /// The Mac holds the link of `generation` while the app is suspended
        /// (PROTOCOL.md "Parked link"): nothing on it wakes the phone, and on
        /// `resume` it is roamed and probed instead of redialed.
        case parked(generation: Int)
        /// The park's hold ran out while the app was away: `resume` redials.
        case parkLapsed
        /// Something needs the link awake (a call on it, a notification
        /// action's request): no park while any hold is out, and a parked
        /// link resumes at once. Each is paired with one `releaseAwake`.
        case holdAwake
        /// One hold ended; with none left, a link in the background parks.
        case releaseAwake
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
        /// The link kept beside a redial (``LinkMachine/standby``) answered a
        /// probe: its path is back, so it is the link again and the redial
        /// is dropped. Its channels never closed.
        case standbyAlive(generation: Int, path: LinkPathKind, rttMillis: UInt32?)
        /// The standby link closed, or stayed silent past
        /// ``LinkController/standbyLimit``.
        case standbyLost(generation: Int)
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
        /// Ask the Mac to hold the live link while the app is suspended; an
        /// accepted park comes back as `parked`.
        case park(generation: Int)
        /// Bring a parked link back: roam its tunnel onto a fresh socket and
        /// probe it once. A failure comes back as `probeFailed` (a redial).
        case resumeParked(generation: Int)
        /// Keep the live link (and every channel on it) as the standby
        /// instead of closing it; a dial follows. Make before break: a
        /// blackout (an elevator, a dead NAT mapping) that ends before the
        /// new dial lands resumes on the old link with nothing re-attached.
        case keepStandby
        /// The standby link is the link again, under `generation`: watch and
        /// probe it, cancel the redial. Nothing is re-attached.
        case promoteStandby(generation: Int)
        /// Close the standby link (the redial won, or it died).
        case closeStandby
    }

    public private(set) var phase: Phase = .idle
    public private(set) var target: Target?
    public private(set) var transport: TransportKind
    /// Debug "simulate distant network": dials skip every direct path.
    public private(set) var relayOnly: Bool
    /// Debug "simulate a network that blocks UDP": WireGuard rides TURN over TLS.
    public private(set) var blockUDP: Bool
    public private(set) var generation = 0
    /// The generation of a link kept beside a redial after its probe failed
    /// (``Effect/keepStandby``); nil when there is none.
    public private(set) var standby: Int?
    public private(set) var isBackgrounded = false
    /// The generation whose link the Mac holds while the app is suspended.
    private var parkedGeneration: Int?
    /// The current link is parked: nothing may probe it (a ping ends the
    /// Mac's park while the phone is about to be suspended).
    public var isParked: Bool { parkedGeneration == generation }
    /// Holds that keep the link out of the park (`holdAwake`).
    public private(set) var awakeHolds = 0
    /// The current link's WebRTC media session (browser video), `off` between links.
    public private(set) var media: VideoMediaState = .off
    /// The last dial found no way to the Mac on this network (`network_blocked`):
    /// what the status line says (once the quiet bound passed) while the quiet
    /// retries go on, until a dial succeeds or the target or transport changes.
    public private(set) var networkBlock: NetworkBlock?
    /// The dial whose `networkBlocked` set ``networkBlock``: a later dial that
    /// fails for another reason (no `networkBlocked` before its `dialFailed`,
    /// say the Mac went to sleep) clears it, so the line never blames the
    /// network for a failure it did not cause.
    private var networkBlockGeneration: Int?
    /// Retry delays in seconds after the silent retries; the last one repeats.
    /// About the first 75 s of an outage retries every 5 s or sooner (an elevator,
    /// a tunnel, Wi-Fi coming back with no path change iOS reports), then relaxes
    /// to the old 10, 15, 30. Leo, 11-25: "I feel like iOS doesn't retry
    /// connections aggressively enough." (`network_flaps` in the reliability matrix.)
    public var backoff: [Int] = [1, 2, 2, 3, 3] + Array(repeating: 5, count: 13) + [10, 15, 30]
    /// A background shorter than this keeps the link: a quick probe, no redial.
    public static let shortSuspend: Duration = .seconds(30)
    /// Failed dials retried at once, before any failure shows.
    public static let silentRetries = 1
    /// Whether an unanswered probe keeps the link beside the redial
    /// (``Effect/keepStandby``). Off only in tests that measure the old way.
    public var keepsStandby = true

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
            let wasBackgrounded = isBackgrounded
            isBackgrounded = true
            // Park only a live link nothing holds awake, once per stay in the
            // background (a hold's release parks it later).
            guard !wasBackgrounded, awakeHolds == 0, phase.isConnected, !isParked else { return [] }
            return [.park(generation: generation)]
        case .parked(let gen):
            guard gen == generation, isBackgrounded, phase.isConnected else { return [] }
            // A hold came while the park was being asked for: take it back.
            guard awakeHolds == 0 else { return [.resumeParked(generation: gen)] }
            parkedGeneration = gen
            return []
        case .parkLapsed:
            parkedGeneration = nil
            return []
        case .holdAwake:
            awakeHolds += 1
            guard isParked, phase.isConnected else { return [] }
            parkedGeneration = nil
            return [.resumeParked(generation: generation)]
        case .releaseAwake:
            awakeHolds = max(awakeHolds - 1, 0)
            guard awakeHolds == 0, isBackgrounded, phase.isConnected, !isParked else { return [] }
            return [.park(generation: generation)]
        case .resume:
            let wasBackgrounded = isBackgrounded
            isBackgrounded = false
            if wasBackgrounded, isParked, phase.isConnected {
                // The Mac kept the link: roam it and probe once, no redial.
                parkedGeneration = nil
                return [.resumeParked(generation: generation)]
            }
            // A link held awake was never suspended (a call kept the app
            // running): probe it as on any foreground, no redial.
            guard awakeHolds == 0 else { return handle(.foreground) }
            // Back from the background a connected link is kept beside the
            // redial (make before break), not closed first: after a short
            // background (another app for a few seconds) the Mac still holds
            // it, its first probe answers in one round trip and the chat goes
            // on with nothing re-attached. After a long one it is silent, and
            // the redial, sent at the same moment, wins as before.
            if wasBackgrounded, keepsStandby, case .connected = phase {
                let kept = generation
                let effects = dropStandby() + [.keepStandby] + dial(attempt: 1, closing: false)
                standby = kept
                return effects
            }
            if wasBackgrounded, isActive {
                return dial(attempt: 1, closing: true)
            }
            return handle(.foreground)
        case .resumed(let away):
            let wasBackgrounded = isBackgrounded
            isBackgrounded = false
            if wasBackgrounded, isParked, phase.isConnected {
                // The Mac kept the link: roam it and probe once, no redial.
                parkedGeneration = nil
                return [.resumeParked(generation: generation)]
            }
            // A link held awake was never suspended (a call kept the app running):
            // probe it as on any foreground.
            guard wasBackgrounded, isActive, awakeHolds == 0 else { return handle(.foreground) }
            // A dial or a wait in flight across the suspension started on a path that may be
            // gone: start it again, as before.
            guard case .connected = phase else { return dial(attempt: 1, closing: true) }
            // Short: the link is almost always alive. Keep it and every channel on it; an
            // unanswered probe takes the probe-failed path (standby beside a redial).
            if away < Self.shortSuspend { return [.quickProbe(generation: generation)] }
            // Long: the link may be stale. Dial at once, but keep it beside the dial; if it
            // answers first, nothing was re-attached.
            guard keepsStandby else { return dial(attempt: 1, closing: true) }
            let kept = generation
            let effects = dropStandby() + [.keepStandby] + dial(attempt: 1, closing: false)
            standby = kept
            return effects
        case .target(let next):
            let sameMac = next?.macID == target?.macID
            if !sameMac { networkBlock = nil }
            target = next
            guard let next else { return reset(to: .idle) }
            if !next.isOnline {
                // Presence is signaling, the link is peer to peer: a reset of
                // the Mac's signaling socket (a Worker deploy) says "offline"
                // for a moment while the link is fine. Keep it and probe it;
                // a dead one fails the probe (termfix-r13 D2a, T-LIFE-17).
                if sameMac, case .connected = phase { return isParked ? [] : [.quickProbe(generation: generation)] }
                // A dial a surface asked for (``Event/open``) is left to finish:
                // its own failure says whether the Mac is offline.
                if sameMac, case .connecting = phase { return [] }
                return reset(to: .macOffline)
            }
            if sameMac, isActive { return [] }
            return dial(attempt: 1, closing: true)
        case .transport(let next):
            guard next != transport else { return [] }
            transport = next
            networkBlock = nil
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
            networkBlock = nil
            phase = .connected(transport, path, rttMillis: nil)
            // The new link is up: the old one beside it has nothing left to do.
            return dropStandby()
        case .standbyAlive(let gen, let path, let rtt):
            guard gen == standby else { return [] }
            standby = nil
            switch phase {
            case .connecting, .waiting:
                generation += 1
                networkBlock = nil
                phase = .connected(transport, path, rttMillis: rtt)
                return [.promoteStandby(generation: generation)]
            default:
                return [.closeStandby]
            }
        case .standbyLost(let gen):
            guard gen == standby else { return [] }
            return dropStandby()
        case .networkBlocked(let gen, let block):
            guard gen == generation, case .connecting = phase else { return [] }
            networkBlock = block
            networkBlockGeneration = gen
            return []
        case .dialFailed(let gen, let reason):
            guard gen == generation, case .connecting(_, let attempt) = phase else { return [] }
            if networkBlockGeneration != gen { networkBlock = nil }
            // Presence said offline and a dial (``Event/open``) confirmed it:
            // offline now, no retry loop until presence brings the Mac back.
            if target?.isOnline == false {
                generation += 1
                media = .off
                phase = .macOffline
                return []
            }
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
            // A probe went unanswered on a link that has not closed: the path
            // may only be dark for a while (an elevator, a cell handover, a
            // NAT mapping that died). Keep it beside the redial and keep
            // probing it; whichever answers first carries on. In the
            // background iOS may suspend the process under it, so it closes.
            if case .probeFailed = event, keepsStandby, !isBackgrounded {
                let kept = generation
                let effects = dropStandby() + [.keepStandby] + dial(attempt: 1, closing: false)
                standby = kept
                return effects
            }
            // Redial at once; a failure then takes the usual retry path.
            return [.close] + dial(attempt: 1, closing: false)
        case .macSignaled:
            switch phase {
            case .connected: return isParked ? [] : [.quickProbe(generation: generation)]
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
        // A new path, or the cmux service reachable again (the presence socket's
        // hello after an outage, which covers Wi-Fi back with no path event).
        case .networkChanged:
            switch phase {
            case .waiting(_, let attempt, _, _): return dial(attempt: attempt + 1, closing: false)
            // Without this a retry dial on the dead path waited out its whole
            // dial timeout (25 s) and then a backoff step after the network
            // was back (iOS reliability matrix, network_back_during_inflight_dial).
            case .connecting(_, let attempt): return dial(attempt: attempt, closing: false)
            default: return []
            }
        case .retryDue(let gen):
            guard gen == generation, case .waiting(_, let attempt, _, _) = phase else { return [] }
            return dial(attempt: attempt + 1, closing: false)
        case .open:
            switch phase {
            case .macOffline: return dial(attempt: 1, closing: false)
            case .waiting(_, let attempt, _, _): return dial(attempt: attempt + 1, closing: false)
            default: return []
            }
        case .foreground:
            switch phase {
            case .waiting(_, let attempt, _, _): return dial(attempt: attempt + 1, closing: false)
            // A parked link is probed only by its resume: a ping ends the Mac's park.
            case .connected: return isParked ? [] : [.probe(generation: generation)]
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
        let wasActive = isActive
        generation += 1
        media = .off
        phase = next
        standby = nil
        return wasActive ? [.close] : []
    }

    /// Forget the standby link; the effect that closes it, if there was one.
    private mutating func dropStandby() -> [Effect] {
        guard standby != nil else { return [] }
        standby = nil
        return [.closeStandby]
    }

    private mutating func dial(attempt: Int, closing: Bool) -> [Effect] {
        guard let target else { return [] }
        let wasActive = isActive
        generation += 1
        media = .off
        phase = .connecting(transport, attempt: attempt)
        let effects: [Effect] = [.dial(generation: generation, macID: target.macID, transport: transport)]
        // `.close` closes the standby link too.
        if closing && wasActive { standby = nil }
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

    /// One short line for the Mac's section header and Settings, or nil for
    /// nothing: a connected link and one redialing on its own say nothing
    /// (the header keeps the Mac's name and its cached rows). "Signed out"
    /// stays (the person signs in again); "Offline" is held by the caller
    /// until the link has been down for the shared quiet bound
    /// (`LiveCoordinator.statusLines`). Transport, path, latency, and daemon
    /// failures remain available to diagnostics. `block`: the network blocks
    /// the link (``LinkMachine/networkBlock``): while it is down, the line
    /// says so and what to do (held by the same quiet bound), and the quiet
    /// retries go on beneath it.
    public func statusLine(macName _: String, media _: VideoMediaState = .off, block: NetworkBlock? = nil) -> String? {
        if let block {
            switch self {
            case .connecting, .waiting: return block.statusLine
            default: break
            }
        }
        return switch self {
        case .idle, .connecting, .connected: nil
        case .macOffline: "Offline"
        case .signedOut: "Signed out"
        case .waiting(_, _, let reason, _):
            reason == LinkController.reason(LinkError(code: "offline", message: "")) ? "Offline" : nil
        }
    }

    /// Technical detail for the explicit diagnostics disclosure only.
    public func diagnosticLine(macName: String, media: VideoMediaState = .off, block: NetworkBlock? = nil) -> String? {
        if let block {
            switch self {
            case .connecting, .waiting: return block.sentence
            default: break
            }
        }
        return switch self {
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

    /// Connected on the same transport and path as `other`, with only the
    /// measured round trip changed: a pong. Over LTE every pong's round trip
    /// differs, so this is most phase changes on a link that is up.
    public func differsOnlyInRoundTrip(from other: Self) -> Bool {
        guard case .connected(let transport, let path, _) = self,
              case .connected(let otherTransport, let otherPath, _) = other else { return false }
        return transport == otherTransport && path == otherPath
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
        case .httpsRelay: "relay (cmux, HTTPS)"
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
