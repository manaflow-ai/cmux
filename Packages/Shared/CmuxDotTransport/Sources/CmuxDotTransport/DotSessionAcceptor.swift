// Mac-side acceptor: runs the standing host leg, answers phone handshakes,
// verifies pair grants against the pinned trust keys, and emits admitted
// sessions. One session per phone leg id; a new hs1 on a live leg (or from
// the same device on a new leg) supersedes the old session.
public import Foundation

public actor DotSessionAcceptor {
    private let configuration: DotSessionAcceptorConfiguration
    private let journal: DotJournal

    private var leg: DotLeg?
    private var legLoop: Task<Void, Never>?
    private var continuation: AsyncStream<DotAcceptorEvent>.Continuation?
    private var stopped = false

    private var sessionsByLeg: [UInt32: DotMuxSession] = [:]
    private var legByDevice: [String: UInt32] = [:]
    /// Handshakes mid-verification per source leg; duplicate hs1 arriving
    /// while one is in flight would mint two sessions under different keys.
    private var respondingLegs: Set<UInt32> = []

    public init(configuration: DotSessionAcceptorConfiguration) {
        self.configuration = configuration
        self.journal = configuration.leg.journal
    }

    public func start() -> AsyncStream<DotAcceptorEvent> {
        let (stream, continuation) = AsyncStream<DotAcceptorEvent>.makeStream()
        self.continuation = continuation
        guard !stopped, leg == nil else {
            continuation.finish()
            return stream
        }
        let leg = DotLeg(configuration: configuration.leg)
        self.leg = leg
        legLoop = Task { [weak self] in
            let events = await leg.start()
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.handleLegEvent(event)
            }
            await self?.legStreamFinished()
        }
        return stream
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        legLoop?.cancel()
        legLoop = nil
        for session in sessionsByLeg.values {
            await session.fail(reason: "acceptor-stopped")
        }
        sessionsByLeg = [:]
        legByDevice = [:]
        if let leg {
            await leg.stop()
        }
        leg = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Leg events

    private func handleLegEvent(_ event: DotLegEvent) async {
        guard !stopped else { return }
        switch event {
        case .frame(let sourceLegID, let payload):
            await handleFrame(sourceLegID: sourceLegID, payload: payload)
        case .reset(let reason):
            // Host leg continuity lost: every phone session's sealed stream
            // is broken. End them all; phones re-handshake on peer.online.
            for session in sessionsByLeg.values {
                await session.fail(reason: "leg-reset: \(reason)")
            }
            sessionsByLeg = [:]
            legByDevice = [:]
            continuation?.yield(.legEvent(event))
        case .peerOffline:
            // The phone leg may resume invisibly; its session stays. Stale
            // sessions from legs that never return are superseded by the
            // device's next handshake.
            continuation?.yield(.legEvent(event))
        case .closed:
            for session in sessionsByLeg.values {
                await session.fail(reason: "leg-closed")
            }
            sessionsByLeg = [:]
            legByDevice = [:]
            continuation?.yield(.legEvent(event))
        case .up, .peerOnline, .suspended, .resumed:
            continuation?.yield(.legEvent(event))
        }
    }

    private func legStreamFinished() {
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Frames

    private func handleFrame(sourceLegID: UInt32, payload: Data) async {
        switch payload.first {
        case DotBoxKind.handshake.rawValue:
            await handleHandshake(sourceLegID: sourceLegID, payload: payload)
        case DotBoxKind.sealed.rawValue:
            if let session = sessionsByLeg[sourceLegID] {
                await session.handleInboundSealed(payload)
            }
        default:
            journal.record(
                component: "acceptor", event: "unknown-frame-kind",
                attributes: ["leg": String(sourceLegID)]
            )
        }
    }

    private func handleHandshake(sourceLegID: UInt32, payload: Data) async {
        guard !respondingLegs.contains(sourceLegID) else {
            // Duplicate hs1 while the first is mid-verification (phone retry
            // racing a slow judge); answering both would double-key the leg.
            return
        }
        respondingLegs.insert(sourceLegID)
        defer { respondingLegs.remove(sourceLegID) }

        // A re-handshake on a live leg replaces its session (the phone only
        // re-handshakes when its side of the session is gone).
        if let existing = sessionsByLeg.removeValue(forKey: sourceLegID) {
            await existing.fail(reason: "superseded")
        }
        let outcome: DotHandshakeResponder.Outcome
        do {
            outcome = try await DotHandshakeResponder.respond(
                hs1Payload: payload,
                identity: configuration.identity,
                admission: configuration.admission,
                judge: configuration.judge
            )
        } catch DotHandshakeError.denied(let reason) {
            if let leg {
                try? await leg.send(
                    DotHandshakeDeny.payload(reason: reason), to: sourceLegID)
            }
            continuation?.yield(.denied(deviceID: nil, reason: reason))
            return
        } catch {
            // Malformed or mis-signed hs1: not a policy denial; drop it
            // silently (could be noise or probing).
            journal.record(
                component: "acceptor", event: "hs1-rejected",
                attributes: [
                    "leg": String(sourceLegID),
                    "reason": String(describing: error),
                ]
            )
            return
        }

        // The same phone re-handshaking from a NEW leg (its old leg reset)
        // leaves a stale session behind; retire it now.
        if let staleLeg = legByDevice[outcome.peer.deviceID],
            staleLeg != sourceLegID,
            let stale = sessionsByLeg.removeValue(forKey: staleLeg)
        {
            await stale.fail(reason: "superseded-by-device")
        }

        guard let leg else { return }
        do {
            // hs2 first, admit second: both ride the same per-destination
            // seq order, so the phone always sees hs2 before the sealed admit.
            try await leg.send(outcome.hs2Payload, to: sourceLegID)
        } catch {
            journal.record(
                component: "acceptor", event: "hs2-send-failed",
                attributes: ["reason": String(describing: error)]
            )
            return
        }
        let sessionID = outcome.sessionID
        let session = DotMuxSession(
            role: .responder,
            keys: outcome.keys,
            peer: outcome.peer,
            sessionID: sessionID,
            journal: journal,
            transmit: { data in
                try await leg.send(data, to: sourceLegID)
            },
            onEnd: { [weak self] reason in
                Task {
                    await self?.sessionEnded(
                        legID: sourceLegID, sessionID: sessionID, reason: reason)
                }
            }
        )
        sessionsByLeg[sourceLegID] = session
        legByDevice[outcome.peer.deviceID] = sourceLegID
        await session.begin()
        continuation?.yield(.admitted(session))
    }

    private func sessionEnded(legID: UInt32, sessionID: String, reason: String) {
        if let session = sessionsByLeg[legID], session.sessionID == sessionID {
            sessionsByLeg[legID] = nil
        }
        for (device, mappedLeg) in legByDevice where mappedLeg == legID {
            if sessionsByLeg[legID] == nil {
                legByDevice[device] = nil
            }
        }
        _ = reason
    }
}
