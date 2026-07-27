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
/// so clean close and resubscribe is the steady state). Against a pre-nudge
/// worker the same endpoint serves snapshot/presence frames; the decoder
/// ignores everything that is not a nudge, so old servers just make this a
/// slightly chattier no-op.
@MainActor
final class PresenceNudgeSubscriber {
    static let shared = PresenceNudgeSubscriber()

    private var auth: AuthCoordinator?
    private var loopTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?

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
        evaluate()
    }

    func appWillTerminate() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func evaluate() {
        let shouldRun = auth != nil
            && PresenceSettings.isEnabled()
            && PresenceHeartbeatClient.resolvedServiceURL() != nil
        if shouldRun, loopTask == nil {
            startLoop()
        } else if !shouldRun, loopTask != nil {
            loopTask?.cancel()
            loopTask = nil
        }
    }

    private func startLoop() {
        loopTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var failureDelay: Duration = .seconds(1)
            while !Task.isCancelled {
                guard let self else { return }
                let streamDelivered = await self.subscribeOnce()
                if Task.isCancelled { return }
                // A stream that delivered anything (even the expiry close after
                // minutes of silence counts as normal service) resubscribes
                // promptly; hard connect failures back off.
                if streamDelivered {
                    failureDelay = .seconds(1)
                } else {
                    failureDelay = min(failureDelay * 2, .seconds(60))
                }
                guard (try? await clock.sleep(for: failureDelay)) != nil else { return }
            }
        }
    }

    /// Opens one bounded subscription stream and pumps it until the service
    /// closes it (token expiry), it errors, or the loop is cancelled. Returns
    /// whether the stream connected well enough to deliver at least one frame
    /// or a clean service-side close.
    private func subscribeOnce() async -> Bool {
        guard let auth, let baseURL = PresenceHeartbeatClient.resolvedServiceURL() else {
            return false
        }
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch {
            return false // not signed in; evaluate() restarts on auth change
        }
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path)
            + "/v1/presence/subscribe"
        comps.queryItems = [URLQueryItem(
            name: "deviceScope",
            value: MobileHostIdentity.deviceID()
        )]
        guard let url = comps.url else { return false }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let teamID = auth.resolvedTeamID, !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        var delivered = false
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                // Normal service-side close at token expiry surfaces here too;
                // `delivered` decides whether this stream counted as healthy.
                return delivered
            }
            delivered = true
            switch message {
            case let .string(text):
                handleFrame(text)
            case let .data(data):
                if let text = String(data: data, encoding: .utf8) {
                    handleFrame(text)
                }
            @unknown default:
                break
            }
        }
        return delivered
    }

    private func handleFrame(_ text: String) {
        guard let payload = try? JSONSerialization.jsonObject(
            with: Data(text.utf8)
        ) as? [String: Any] else { return }
        // Everything except a nudge for this device (an old worker's snapshot
        // or presence chatter) is ignored.
        guard payload["type"] as? String == "nudge",
              let deviceID = payload["deviceId"] as? String,
              deviceID.caseInsensitiveCompare(MobileHostIdentity.deviceID()) == .orderedSame
        else { return }
        if let tag = payload["tag"] as? String,
           !tag.isEmpty,
           tag != MobileHostIdentity.instanceTag() {
            return // directed at another app instance (build tag) on this Mac
        }
        let kind = payload["kind"] as? String ?? "unknown"
        mobileHostIrohLog.info(
            "Presence nudge received (\(kind, privacy: .public)); refreshing iroh registration"
        )
        MobileHostIrohRuntime.shared.refreshRegistrationFromServerSignal()
    }
}
