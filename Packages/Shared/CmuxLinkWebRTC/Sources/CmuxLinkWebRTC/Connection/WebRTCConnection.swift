import CmuxLinkSignaling
import CmuxLink
import Foundation
@preconcurrency import WebRTC

/// Drives one peer connection through signaling, authentication, liveness,
/// ICE restarts, path classification and the graceful close (b2-webrtc.md
/// sections 4 to 8). Signals and peer events are each handled in arrival
/// order; the actor serializes the two sources.
actor WebRTCConnection {
    let role: WebRTCConnectionRole
    let context: WebRTCConnectionContext
    nonisolated let peer: WebRTCPeer
    nonisolated let pacer: SendPacer
    private let onFinish: @Sendable (WebRTCConnection) -> Void

    /// Where our signals go: the host id (dialer) or the dialer's install (host).
    private(set) var remoteTarget: String
    private(set) var remoteKey: WebRTCPublicKey?
    private(set) var remoteInstall: String?

    // Negotiation.
    private var remoteDescriptionSet = false
    private var pendingCandidates: [ICECandidateInit] = []
    /// The fingerprint of the last offer we sent (an answer must commit to it).
    private var ourOfferFingerprint: DTLSFingerprint?
    private var initialNegotiationDone = false
    private var negotiationNeeded = false
    private var makingOffer = false
    private var restartPending = false

    // Liveness.
    private var controlOpen = false
    private var live = false
    private var liveWaiter: CheckedContinuation<Void, any Error>?
    private(set) var finished = false
    private(set) var endKind: WebRTCEndKind = .open
    private var pathKind: PathKind = .p2p
    private var forcedPath: PathKind?
    private var connectTimer: Task<Void, Never>?
    /// Steady-state ICE stats sampling. The task is owned by this actor and
    /// is cancelled when the connection finishes; connect and ICE transition
    /// samples still happen even when the interval is disabled.
    private var rttTask: Task<Void, Never>?
    private enum TimerSlot: Hashable {
        case grace
        case restart
    }

    private var timers: [TimerSlot: Task<Void, Never>] = [:]
    private var finAckWaiter: CheckedContinuation<Void, Never>?
    private var loops: [Task<Void, Never>] = []

    // Media.
    private var remoteTracks: [String: RemoteTrackBox] = [:]
    private var trackDescriptors: [String: MediaTrackDescriptor] = [:]
    private var mediaBackings: [any WebRTCMediaBacking] = []

    init(
        role: WebRTCConnectionRole,
        context: WebRTCConnectionContext,
        peer: WebRTCPeer,
        remoteTarget: String,
        onFinish: @escaping @Sendable (WebRTCConnection) -> Void
    ) {
        self.role = role
        self.context = context
        self.peer = peer
        self.remoteTarget = remoteTarget
        self.onFinish = onFinish
        pacer = SendPacer(bytesPerSecond: context.injector?.currentRate, clock: context.configuration.clock)
        forcedPath = context.injector?.currentPathOverride
        if case let .dialer(hostKey) = role { remoteKey = hostKey }
    }

    var path: LinkPath { LinkPath(kind: pathKind, carrier: .webrtc) }

    // MARK: Start

    /// Dialer: offers and waits for an authenticated, open control channel.
    func dial() async throws {
        try peer.createPrimaryChannel()
        startLoops()
        startConnectTimer()
        do {
            try await offer()
        } catch {
            finish(.pathLost("offer failed: \(error)"), bye: .failed)
            throw WebRTCCarrierError.connectFailed("\(error)")
        }
        try await waitLive()
    }

    /// Host: handles the offer at the head of `inbox` and waits for liveness.
    func accept() async throws {
        startConnectTimer()
        try await waitLive()
    }

    func attach(inbox: AsyncStream<SignalMessage>) {
        loops.append(Task { [weak self] in
            for await message in inbox {
                guard let self else { return }
                await self.handle(message)
            }
        })
    }

    private func startLoops() {
        let events = peer.events
        loops.append(Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
            // The peer ended itself (receive overflow, event backlog) or was
            // closed by `finish`, which makes this a no-op.
            await self?.peerEventsEnded()
        })
    }

    private func peerEventsEnded() {
        guard !finished else { return }
        finish(.pathLost(peer.abortReason ?? "peer connection closed"), bye: .closed)
    }

    func startHost(inbox: AsyncStream<SignalMessage>) {
        startLoops()
        attach(inbox: inbox)
    }

    private func startConnectTimer() {
        let clock = context.configuration.clock
        let limit = context.configuration.connectTimeout
        connectTimer = Task { [weak self] in
            guard (try? await clock.sleep(for: limit)) != nil else { return }
            await self?.connectTimedOut()
        }
    }

    private func connectTimedOut() {
        guard !live, !finished else { return }
        finish(.pathLost("connect timed out"), bye: .failed)
    }

    private func waitLive() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if live {
                    continuation.resume()
                } else if finished {
                    continuation.resume(throwing: WebRTCCarrierError.connectFailed("closed"))
                } else {
                    liveWaiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelConnect() }
        }
    }

    private func cancelConnect() {
        guard !live else { return }
        finish(.local, bye: .closed)
    }

    /// Whether descriptions carry and require fingerprint bindings.
    private var authenticated: Bool { context.identity != nil }

    private func checkLive() async {
        guard !live, !finished, controlOpen, initialNegotiationDone, remoteKey != nil || !authenticated else { return }
        if let stats = await peer.selectedPairStats() {
            pathKind = CandidatePairClassifier().kind(local: stats.local, remote: stats.remote)
            if let rtt = stats.rtt { peer.inbox.yield(.rtt(rtt)) }
        }
        guard !live, !finished else { return }
        if let forcedPath { pathKind = forcedPath }
        live = true
        connectTimer?.cancel()
        connectTimer = nil
        startRTTMonitor()
        context.injector?.register(self)
        liveWaiter?.resume()
        liveWaiter = nil
    }

    private func startRTTMonitor() {
        guard rttTask == nil,
              let interval = context.configuration.rttSampleInterval,
              interval > .zero,
              !finished
        else { return }
        let clock = context.configuration.clock
        rttTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard (try? await clock.sleep(for: interval)) != nil else { return }
                guard !Task.isCancelled else { return }
                await self.sampleRTT()
            }
        }
    }

    private func sampleRTT() async {
        guard live, !finished, let stats = await peer.selectedPairStats() else { return }
        if forcedPath == nil {
            applyPath(CandidatePairClassifier().kind(local: stats.local, remote: stats.remote))
        }
        if let rtt = stats.rtt { peer.inbox.yield(.rtt(rtt)) }
    }

    // MARK: Signals

    private func handle(_ message: SignalMessage) async {
        guard !finished else { return }
        switch message.payload {
        case let .offer(sdp, _, _, auth):
            if !initialNegotiationDone, case let .host(authorizer) = role {
                await acceptInitialOffer(sdp: sdp, auth: auth, from: message.from, authorizer: authorizer)
            } else {
                await acceptRenegotiation(sdp: sdp, auth: auth)
            }
        case let .answer(sdp, auth):
            await acceptAnswer(sdp: sdp, auth: auth)
        case let .ice(candidate):
            if remoteDescriptionSet {
                try? await peer.addCandidate(candidate)
            } else {
                pendingCandidates.append(candidate)
            }
        case .iceEnd:
            break
        case let .bye(reason):
            endKind = .reset
            finish(.pathLost("peer said bye: \(reason.rawValue)"), bye: nil)
        }
    }

    private func acceptInitialOffer(sdp: String, auth: SignalAuth?, from: String?, authorizer: (any WebRTCAuthorizer)?) async {
        if let from { remoteTarget = from }
        remoteInstall = from
        let offerFingerprint: DTLSFingerprint
        do {
            guard let fingerprint = DTLSFingerprint(sdp: sdp) else { throw WebRTCAuthError.badFingerprint }
            offerFingerprint = fingerprint
            if authenticated {
                let key = try binding(.offer, fingerprint: fingerprint).verify(auth)
                guard let authorizer, await authorizer.authorize(device: key, install: from) else {
                    throw WebRTCAuthError.unauthorizedDevice
                }
                remoteKey = key
            }
        } catch {
            finish(.pathLost("offer refused: \(error)"), bye: .revoked)
            return
        }
        do {
            try await peer.setRemote(sdp, type: .offer)
            await remoteDescriptionApplied()
            try await answer(offerFingerprint: offerFingerprint)
        } catch {
            finish(.pathLost("answer failed: \(error)"), bye: .failed)
            return
        }
        initialNegotiationDone = true
        await checkLive()
    }

    private func acceptRenegotiation(sdp: String, auth: SignalAuth?) async {
        // The host is the impolite peer: a colliding dialer offer is ignored,
        // the dialer rolls back and answers ours, then offers again.
        if !role.isDialer, makingOffer || peer.signalingState == .haveLocalOffer { return }
        guard initialNegotiationDone else { return }
        do {
            guard let fingerprint = DTLSFingerprint(sdp: sdp) else { throw WebRTCAuthError.badFingerprint }
            if authenticated {
                let key = try binding(.offer, fingerprint: fingerprint).verify(auth)
                guard key == remoteKey else { throw WebRTCAuthError.wrongHostKey }
            }
            // The dialer is polite: implicit rollback drops its own pending offer.
            try await peer.setRemote(sdp, type: .offer)
            await remoteDescriptionApplied()
            try await answer(offerFingerprint: fingerprint)
        } catch let error as WebRTCAuthError {
            finish(.pathLost("renegotiation refused: \(error)"), bye: .revoked)
            return
        } catch {
            finish(.pathLost("renegotiation failed: \(error)"), bye: .failed)
            return
        }
        await offerIfNeeded()
    }

    private func acceptAnswer(sdp: String, auth: SignalAuth?) async {
        guard peer.signalingState == .haveLocalOffer, let ourOfferFingerprint else { return }
        do {
            guard let fingerprint = DTLSFingerprint(sdp: sdp) else { throw WebRTCAuthError.badFingerprint }
            if authenticated {
                let key = try binding(.answer, fingerprint: fingerprint, offerFingerprint: ourOfferFingerprint).verify(auth)
                guard key == remoteKey else {
                    throw role.isDialer ? WebRTCAuthError.wrongHostKey : WebRTCAuthError.unauthorizedDevice
                }
            }
            try await peer.setRemote(sdp, type: .answer)
            await remoteDescriptionApplied()
        } catch let error as WebRTCAuthError {
            finish(.pathLost("answer refused: \(error)"), bye: .revoked)
            return
        } catch {
            finish(.pathLost("answer failed: \(error)"), bye: .failed)
            return
        }
        if !initialNegotiationDone {
            initialNegotiationDone = true
            await checkLive()
        }
        await offerIfNeeded()
    }

    private func remoteDescriptionApplied() async {
        remoteDescriptionSet = true
        let pending = pendingCandidates
        pendingCandidates = []
        for candidate in pending { try? await peer.addCandidate(candidate) }
    }

    private func binding(_ role: FingerprintBinding.Role, fingerprint: DTLSFingerprint, offerFingerprint: DTLSFingerprint? = nil) -> FingerprintBinding {
        FingerprintBinding(
            role: role, session: context.session, hostID: context.hostID,
            fingerprint: fingerprint, offerFingerprint: offerFingerprint
        )
    }

    private func offer() async throws {
        makingOffer = true
        defer { makingOffer = false }
        let iceRestart = restartPending
        restartPending = false
        let sdp = try await peer.makeOffer()
        guard let fingerprint = DTLSFingerprint(sdp: sdp) else { throw WebRTCAuthError.badFingerprint }
        ourOfferFingerprint = fingerprint
        let auth = try context.identity.map { try binding(.offer, fingerprint: fingerprint).sign(with: $0) }
        try await context.signaling.send(SignalMessage(
            session: context.session, to: remoteTarget,
            payload: .offer(sdp: sdp, iceRestart: iceRestart, carrier: peer.mode.carrier, auth: auth)
        ))
    }

    private func answer(offerFingerprint: DTLSFingerprint) async throws {
        let sdp = try await peer.makeAnswer()
        guard let fingerprint = DTLSFingerprint(sdp: sdp) else { throw WebRTCAuthError.badFingerprint }
        let auth = try context.identity.map {
            try binding(.answer, fingerprint: fingerprint, offerFingerprint: offerFingerprint).sign(with: $0)
        }
        try await context.signaling.send(SignalMessage(
            session: context.session, to: remoteTarget, payload: .answer(sdp: sdp, auth: auth)
        ))
    }

    /// Runs a deferred renegotiation once signaling is stable.
    private func offerIfNeeded() async {
        guard negotiationNeeded, !makingOffer, !finished, initialNegotiationDone, peer.signalingState == .stable else { return }
        negotiationNeeded = false
        do {
            try await offer()
        } catch {
            finish(.pathLost("renegotiation offer failed: \(error)"), bye: .failed)
        }
    }

    // MARK: Peer events

    private func handle(_ event: PeerEvent) async {
        switch event {
        case let .candidate(candidate):
            guard !finished, allowed(candidate) else { return }
            try? await context.signaling.send(SignalMessage(session: context.session, to: remoteTarget, payload: .ice(candidate)))
        case .gatheringComplete:
            guard !finished else { return }
            try? await context.signaling.send(SignalMessage(session: context.session, to: remoteTarget, payload: .iceEnd))
        case let .iceState(state):
            await iceStateChanged(state)
        case let .selectedPair(local, remote):
            if let kind = CandidatePairClassifier().kind(localLine: local, remoteLine: remote) { applyPath(kind) }
        case .negotiationNeeded:
            guard initialNegotiationDone, !finished else { return }
            negotiationNeeded = true
            await offerIfNeeded()
        case .controlOpen:
            controlOpen = true
            await checkLive()
        case .controlClosed:
            if finished {
                peer.close()
            } else {
                finish(.pathLost("control channel closed"), bye: nil)
            }
        case let .control(message):
            controlMessage(message)
        case .finSatisfied:
            guard !finished else { return }
            finish(.remote, bye: nil, closePeer: false)
            _ = peer.sendControl(.finAck)
        case let .remoteTrack(box):
            remoteTracks[box.track.trackId] = box
            pairTracks()
        }
    }

    private func allowed(_ candidate: ICECandidateInit) -> Bool {
        guard context.configuration.network == .loopbackOnly else { return true }
        let tokens = candidate.candidate.split(separator: " ")
        guard tokens.count > 4 else { return false }
        let address = tokens[4]
        return address == "127.0.0.1" || address == "::1"
    }

    private func controlMessage(_ message: CarrierControlMessage) {
        switch message {
        case let .fin(counts):
            peer.expectFin(counts)
        case .finAck:
            finAckWaiter?.resume()
            finAckWaiter = nil
        case let .track(descriptor):
            trackDescriptors[descriptor.id] = descriptor
            pairTracks()
        case .credit:
            // The peer handles credits itself (lane scheduler).
            break
        }
    }

    // MARK: ICE

    private func iceStateChanged(_ state: RTCIceConnectionState) async {
        guard !finished else { return }
        switch state {
        case .connected, .completed:
            for timer in timers.values { timer.cancel() }
            timers = [:]
            if live, forcedPath == nil, let stats = await peer.selectedPairStats() {
                applyPath(CandidatePairClassifier().kind(local: stats.local, remote: stats.remote))
                if let rtt = stats.rtt { peer.inbox.yield(.rtt(rtt)) }
            }
        case .disconnected:
            guard live else { return }
            if role.isDialer {
                schedule(.grace, after: context.configuration.disconnectedGrace) { await $0.restartICE() }
            } else {
                armRestartDeadline(extra: context.configuration.disconnectedGrace)
            }
        case .failed:
            guard live else {
                finish(.pathLost("ICE failed"), bye: .failed)
                return
            }
            if role.isDialer { await restartICE() } else { armRestartDeadline(extra: .zero) }
        default:
            break
        }
    }

    /// Dialer: fresh ICE servers, `restartIce`, and an offer with
    /// `ice_restart: true`; ends the transport when ICE does not recover by
    /// `iceRestartTimeout`. Host: no-op (the dialer drives restarts).
    func restartICE() async {
        guard role.isDialer, live, !finished, timers[.restart] == nil else { return }
        armRestartDeadline(extra: .zero)
        if let ice = try? await context.iceCache.configuration(for: context.hostID) {
            peer.updateICEServers(ice)
        }
        restartPending = true
        peer.restartICE()
    }

    private func armRestartDeadline(extra: Duration) {
        guard timers[.restart] == nil else { return }
        schedule(.restart, after: context.configuration.iceRestartTimeout + extra) { connection in
            await connection.finish(.pathLost("ICE did not recover"), bye: .failed)
        }
    }

    private func schedule(
        _ slot: TimerSlot,
        after delay: Duration,
        _ action: @escaping @Sendable (WebRTCConnection) async -> Void
    ) {
        timers[slot]?.cancel()
        let clock = context.configuration.clock
        timers[slot] = Task { [weak self] in
            guard (try? await clock.sleep(for: delay)) != nil, let self else { return }
            await self.timerFired(slot, action)
        }
    }

    private func timerFired(
        _ slot: TimerSlot,
        _ action: @Sendable (WebRTCConnection) async -> Void
    ) async {
        timers[slot] = nil
        guard !finished else { return }
        await action(self)
    }

    // MARK: Path

    private func applyPath(_ kind: PathKind) {
        let effective = forcedPath ?? kind
        guard effective != pathKind else { return }
        pathKind = effective
        if live, !finished { peer.inbox.yield(.pathChanged(path)) }
    }

    /// Test hook: moves the reported path without touching ICE.
    func forcePath(_ kind: PathKind) {
        forcedPath = kind
        applyPath(kind)
    }

    // MARK: Media

    func publish(_ descriptor: MediaTrackDescriptor) async throws -> MediaTrackHandle {
        guard live, !finished else { throw WebRTCTransportError.closed }
        guard descriptor.kind == .video else { throw WebRTCTransportError.mediaKindUnsupported(descriptor.kind) }
        guard peer.sendControl(.track(descriptor)) else { throw WebRTCTransportError.closed }
        let backing = try WebRTCLocalVideoTrack(peer: peer, descriptor: descriptor)
        mediaBackings.append(backing)
        return MediaTrackHandle(descriptor: descriptor, backing: backing)
    }

    private func pairTracks() {
        for (id, descriptor) in trackDescriptors {
            guard let box = remoteTracks[id], let video = box.track as? RTCVideoTrack else { continue }
            trackDescriptors[id] = nil
            remoteTracks[id] = nil
            let backing = WebRTCRemoteVideoTrack(track: video)
            mediaBackings.append(backing)
            peer.inbox.yield(.mediaTrack(MediaTrackHandle(descriptor: descriptor, backing: backing)))
        }
    }

    // MARK: Close

    /// Graceful: the peer delivers every reliable frame sent before this,
    /// then sees `.closed(.remote)`; bounded by `closeTimeout`.
    func close() async {
        guard !finished else { return }
        if live, peer.mode == .lanes { await flushLanes() }
        guard !finished else { return }
        guard live, finAckWaiter == nil, peer.sendControl(.fin(counts: peer.sentCounts)) else {
            // No close handshake (not live yet, or the datagram underlay):
            // `bye` tells the peer it is gone.
            finish(.local, bye: .closed)
            return
        }
        let clock = context.configuration.clock
        let limit = context.configuration.closeTimeout
        let timeout = Task { [weak self] in
            guard (try? await clock.sleep(for: limit)) != nil else { return }
            await self?.finAckTimedOut()
        }
        await withCheckedContinuation { finAckWaiter = $0 }
        timeout.cancel()
        finish(.local, bye: nil)
    }

    /// Waits until the lane scheduler handed every queued reliable message
    /// to libwebrtc, so the `fin` counts and follows them; bounded by
    /// `closeTimeout` (a peer that stopped reading).
    private func flushLanes() async {
        let (first, sink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let peer = peer
        let clock = context.configuration.clock
        let limit = context.configuration.closeTimeout
        let flush = Task {
            await peer.waitFlushed()
            sink.yield()
        }
        let timer = Task {
            try? await clock.sleep(for: limit)
            sink.yield()
        }
        for await _ in first { break }
        flush.cancel()
        timer.cancel()
    }

    private func finAckTimedOut() {
        finAckWaiter?.resume()
        finAckWaiter = nil
    }

    /// Test hook: kills the peer connection without a close handshake. With
    /// `bye` the peer learns it is gone (`reset`); without, it sees the path
    /// die.
    func abort(sendBye: Bool = false) {
        if sendBye { endKind = .reset }
        finish(.pathLost("dropped"), bye: sendBye ? .closed : nil)
    }

    /// Ends the connection once: emits `.closed`, fails a pending connect,
    /// tells the peer (`bye`) when it may not notice by itself.
    func finish(_ reason: TransportCloseReason, bye: SignalByeReason?, closePeer: Bool = true) {
        guard !finished else { return }
        finished = true
        if endKind == .open {
            switch reason {
            case .local: endKind = .local
            case .remote: endKind = .remote
            case .pathLost: endKind = .pathLost
            }
        }
        connectTimer?.cancel()
        connectTimer = nil
        rttTask?.cancel()
        rttTask = nil
        for timer in timers.values { timer.cancel() }
        timers = [:]
        liveWaiter?.resume(throwing: WebRTCCarrierError.connectFailed("\(reason)"))
        liveWaiter = nil
        finAckWaiter?.resume()
        finAckWaiter = nil
        if live {
            peer.inbox.yield(.closed(reason))
        }
        peer.inbox.finish()
        for backing in mediaBackings { backing.end() }
        mediaBackings = []
        if closePeer {
            peer.close()
        } else {
            peer.closeWhenControlCloses()
            let clock = context.configuration.clock
            let limit = context.configuration.closeTimeout
            let peer = peer
            Task {
                try? await clock.sleep(for: limit)
                peer.close()
            }
        }
        for loop in loops { loop.cancel() }
        loops = []
        let context = context
        let target = remoteTarget
        Task {
            await context.router.unregister(context.session)
            if let bye {
                try? await context.signaling.send(SignalMessage(session: context.session, to: target, payload: .bye(bye)))
            }
        }
        context.injector?.unregister(self)
        onFinish(self)
    }
}
