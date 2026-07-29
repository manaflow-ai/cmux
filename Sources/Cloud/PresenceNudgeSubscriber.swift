import CMUXMobileCore
import CmuxAuthRuntime
import Foundation

/// Holds a quiet device-scoped WebSocket to the presence service so the
/// server can wake THIS Mac the moment its server-side state changes (for
/// example its iroh broker binding was revoked or replaced), instead of the
/// Mac finding out on its next scheduled broker round trip, which can be
/// most of an hour away.
///
/// The subscription is directed (`?deviceScope=<deviceId>`): the stream
/// carries ONLY `nudge` frames for this device — no snapshot and no team
/// presence chatter — so the socket is silent between events. Delivery is
/// best-effort by design: a nudge only accelerates a re-check the Mac's
/// renewal timer and network observers would run anyway, so a missed frame
/// (asleep, offline, old worker) costs latency, never correctness. Gating
/// (enable flag, service URL, auth) mirrors ``PresenceHeartbeatClient``;
/// reconnect posture mirrors the iOS presence subscriber (backoff 1s→60s,
/// reset when a stream delivers; the service bounds streams to token expiry,
/// so clean close and resubscribe is the steady state). A pre-nudge worker
/// ignores `deviceScope` and serves the full team snapshot plus presence
/// events instead; the FIRST such frame proves the endpoint is legacy, so
/// the subscriber closes immediately and re-probes slowly rather than
/// parsing team-sized traffic on the main actor (see `StreamOutcome`).
@MainActor
final class PresenceNudgeSubscriber {
    static let shared = PresenceNudgeSubscriber()

    private var auth: AuthCoordinator?
    private var loopTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    /// The team/service scope the running loop was started for. A scope change
    /// (team switch, service URL change) restarts the loop so the directed
    /// stream re-subscribes with fresh headers instead of riding the old
    /// socket to the service's 15-minute deadline.
    private var activeScopeKey: String?

    private init() {}

    /// Inject the auth dependency and start (or arm) the subscription. Call
    /// once at the composition root, alongside ``PresenceHeartbeatClient``.
    func configure(auth: AuthCoordinator) {
        self.auth = auth
        if defaultsObserver == nil {
            // Same re-evaluation trigger as the heartbeat client, so flipping
            // the presence flag or service URL applies without a relaunch.
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    PresenceNudgeSubscriber.shared.evaluate()
                }
            }
        }
        armAuthScopeObservation()
        evaluate()
    }

    /// Re-evaluates on every auth identity change (sign-in, sign-out, user or
    /// team switch) via an `@Observable` tracking re-arm loop, so an old
    /// account's socket is torn down the moment the scope changes instead of
    /// riding out the service's 15-minute stream deadline.
    private func armAuthScopeObservation() {
        guard let auth else { return }
        withObservationTracking {
            _ = auth.isAuthenticated
            _ = auth.currentUser?.id
            _ = auth.resolvedTeamID
        } onChange: {
            Task { @MainActor in
                PresenceNudgeSubscriber.shared.evaluate()
                PresenceNudgeSubscriber.shared.armAuthScopeObservation()
            }
        }
    }

    func appWillTerminate() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// The subscription is scoped by the authenticated user, the team, and
    /// the service URL (the connect identity and headers). The user id
    /// matters independently of the team: `resolvedTeamID` is nil for solo
    /// accounts, and the worker scopes a headerless request to the verified
    /// user, so two solo accounts must not share a scope. Token VALUES are
    /// refreshed per reconnect, so they are not part of the key. Signed-out
    /// state yields nil, which tears the loop down.
    private func currentScopeKey() -> String? {
        guard let auth,
              auth.isAuthenticated,
              let userID = auth.currentUser?.id,
              PresenceSettings.isEnabled(),
              let url = PresenceHeartbeatClient.resolvedServiceURL() else { return nil }
        return "\(userID)|\(auth.resolvedTeamID ?? "")|\(url.absoluteString)"
    }

    private func evaluate() {
        let scopeKey = currentScopeKey()
        guard scopeKey != activeScopeKey else { return }
        if loopTask != nil {
            loopTask?.cancel()
            loopTask = nil
        }
        activeScopeKey = scopeKey
        if scopeKey != nil {
            startLoop()
        }
    }

    private enum StreamOutcome {
        /// Never connected usefully; exponential backoff.
        case connectFailed
        /// Served as a directed stream (delivered nudges and/or closed
        /// cleanly at the service deadline); resubscribe promptly.
        case served
        /// The endpoint ignored `deviceScope` (a pre-nudge worker) and sent
        /// presence traffic on what must be a silent directed stream. A
        /// legacy worker has no nudges to send, so nothing is lost by
        /// probing slowly; the only cost is a later first nudge after the
        /// worker upgrades.
        case legacyEndpoint
    }

    private static let legacyReprobeDelay: Duration = .seconds(15 * 60)

    /// How long an EMPTY cleanly-closed stream must have lived to count as
    /// `.served`. The healthy quiet close arrives at the service's 15-minute
    /// deadline, far above this; an accept-then-close loop stays below it and
    /// backs off. Set well under a deployment drain's stream lifetime so a
    /// normal rollout still resubscribes promptly.
    private static let minServedStreamDuration: Duration = .seconds(60)

    private func startLoop() {
        loopTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var failureDelay: Duration = .seconds(1)
            while !Task.isCancelled {
                guard let self else { return }
                let outcome = await self.subscribeOnce()
                if Task.isCancelled { return }
                let delay: Duration
                switch outcome {
                case .served:
                    // Normal service (even the quiet deadline close after
                    // minutes of silence) resubscribes promptly.
                    failureDelay = .seconds(1)
                    delay = failureDelay
                case .connectFailed:
                    failureDelay = min(failureDelay * 2, .seconds(60))
                    delay = failureDelay
                case .legacyEndpoint:
                    failureDelay = .seconds(1)
                    delay = Self.legacyReprobeDelay
                }
                guard (try? await clock.sleep(for: delay)) != nil else { return }
            }
        }
    }

    /// Opens one bounded subscription stream and pumps it until the service
    /// closes it (token expiry), it errors, the endpoint proves legacy, or
    /// the loop is cancelled.
    private func subscribeOnce() async -> StreamOutcome {
        guard let auth, let baseURL = PresenceHeartbeatClient.resolvedServiceURL() else {
            return .connectFailed
        }
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch {
            return .connectFailed // not signed in; evaluate() restarts on auth change
        }
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return .connectFailed
        }
        // URLSessionWebSocketTask requires ws/wss; the service URL is stated as
        // https. Same conversion as the iOS PresenceClient.subscribeURL.
        switch comps.scheme?.lowercased() {
        case "https": comps.scheme = "wss"
        case "http": comps.scheme = "ws"
        case "wss", "ws": break
        default: return .connectFailed
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path)
            + "/v1/presence/subscribe"
        comps.queryItems = [URLQueryItem(
            name: "deviceScope",
            value: MobileHostIdentity.deviceID()
        )]
        guard let url = comps.url else { return .connectFailed }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let teamID = auth.resolvedTeamID, !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        let task = URLSession.shared.webSocketTask(with: request)
        // Enforce the nudge wire bound at the TRANSPORT: receive() fails with
        // EMSGSIZE before an oversized message is buffered, so a legacy
        // worker's team snapshot (megabytes at the service caps) never costs
        // its size in memory, let alone a parse. The in-classifier length
        // check below is second-layer defense.
        task.maximumMessageSize = Self.maxNudgeFrameBytes
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        let streamClock = ContinuousClock()
        let streamStart = streamClock.now

        // `URLSessionWebSocketTask.receive()` does not observe Swift task
        // cancellation, so a cancelled loop would otherwise stay suspended in
        // receive (and the deferred cancel above would never run) until the
        // service's stream deadline. The cancellation handler tears the socket
        // down immediately, which makes the suspended receive throw.
        return await withTaskCancellationHandler {
            var delivered = false
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    // An oversized message can only be a legacy worker's
                    // snapshot/presence traffic (a nudge is ~200 bytes against
                    // the 2 KiB transport bound), so it identifies the
                    // endpoint as legacy just like a parsed foreign frame.
                    if Self.isMessageTooLong(error) { return .legacyEndpoint }
                    // A directed stream is silent between nudges, so a healthy
                    // subscription routinely reaches the service's 15-minute
                    // deadline having delivered nothing. That close arrives as
                    // a normal/going-away close code and must reset backoff,
                    // otherwise every quiet renewal doubles the reconnect gap
                    // and one-shot nudges get lost in it. But the close code
                    // alone is not proof of service: an endpoint that accepts
                    // and immediately closes cleanly in a loop (persistent
                    // drain, misbehaving proxy) would otherwise pin every Mac
                    // at one handshake per second forever. An empty stream
                    // counts as served only when it lived long enough to have
                    // been a real subscription window.
                    if delivered { return .served }
                    let closedCleanly = task.closeCode == .normalClosure
                        || task.closeCode == .goingAway
                    if closedCleanly,
                       streamClock.now - streamStart >= Self.minServedStreamDuration {
                        return .served
                    }
                    return .connectFailed
                }
                guard !Task.isCancelled else { return .served }
                let text: String?
                switch message {
                case let .string(string): text = string
                case let .data(data): text = String(data: data, encoding: .utf8)
                @unknown default: text = nil
                }
                // A nudge-aware worker sends nothing but small text nudge
                // frames on a directed stream, so the first frame that is
                // anything else (a snapshot, presence chatter, binary) proves
                // the endpoint is legacy: stop pumping it instead of paying a
                // main-actor decode for team-sized traffic.
                guard let text, classifyAndHandleFrame(text) == .nudge else {
                    return .legacyEndpoint
                }
                delivered = true
            }
            return .served
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    /// Upper bound of a nudge frame on the wire: fixed keys plus a 36-char
    /// device id, a bounded (≤64) tag, an allowlisted kind, and an epoch —
    /// roughly 200 bytes. Installed as the socket task's
    /// `maximumMessageSize`, so a pre-nudge worker's team snapshot (up to
    /// megabytes) fails the receive before it is buffered; the classifier's
    /// own length check is a second layer.
    private static let maxNudgeFrameBytes = 2048

    /// Whether a receive failure is URLSession rejecting a message larger
    /// than `maximumMessageSize` (POSIX EMSGSIZE, "Message too long").
    private static func isMessageTooLong(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain
            && nsError.code == Int(POSIXErrorCode.EMSGSIZE.rawValue)
    }

    private enum FrameKind {
        case nudge
        case foreign
    }

    /// Classifies one frame, and applies it when it is this instance's nudge.
    /// A nudge for another build tag on this Mac still classifies as `.nudge`:
    /// the stream is healthy and directed, it is just not addressed to us.
    private func classifyAndHandleFrame(_ text: String) -> FrameKind {
        guard text.utf8.count <= Self.maxNudgeFrameBytes,
              let payload = try? JSONSerialization.jsonObject(
                  with: Data(text.utf8)
              ) as? [String: Any],
              payload["type"] as? String == "nudge",
              let deviceID = payload["deviceId"] as? String
        else { return .foreign }
        guard deviceID.caseInsensitiveCompare(MobileHostIdentity.deviceID()) == .orderedSame else {
            return .nudge // server-side scope filter should make this unreachable
        }
        if let tag = payload["tag"] as? String,
           !tag.isEmpty,
           tag != MobileHostIdentity.instanceTag() {
            return .nudge // directed at another app instance (build tag) on this Mac
        }
        let kind = payload["kind"] as? String ?? "unknown"
        mobileHostIrohLog.info(
            "Presence nudge received (\(kind, privacy: .public)); refreshing iroh registration"
        )
        MobileHostIrohRuntime.shared.refreshRegistrationFromServerSignal()
        return .nudge
    }
}
