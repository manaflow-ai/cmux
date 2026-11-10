import AppKit
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import CmuxNextFeedClient

/// The app's side of the feed (plans/cmux-next/feed-page.md): the daemon's feed client owns the
/// mirror of the person's `FeedDO` (on the cloud lease the app gives it with `cloud-session-set`,
/// whose origin is ``apiBaseURL``), the GitHub poller and the reports mailbox; the Feed page draws
/// them. This keeps only what the app alone knows: its active state as presence for the owner's
/// push rule, the GitHub setting, the update cards it posts, and `call` for the native security
/// callers that talk to the API Worker themselves. It also hears each Cloud approval hold the owner
/// closes (answered on any device) for ``CloudApprovalHolds``.
@MainActor
final class FeedService {
    let apiBaseURL: URL
    /// The daemon's `feed.*` ops and their change events.
    let daemon: FeedDaemonClient
    private let auth: CloudAuth
    /// Whether the app is active (`AppServices.appActiveSource`), for the owner's presence; never the global `NSApp`.
    private let appActive: @MainActor () -> Bool
    private var observers: [MainActorObservation] = []
    private var tasks: [Task<Void, Never>] = []
    private let approvalHolds: CloudApprovalHolds?

    /// The API Worker for this build: `CMUX_NEXT_FEED_API_URL`, else staging
    /// for development auth and production for production auth.
    static func apiBaseURL(auth: CloudAuth, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        auth.configuration.ownerAPIBaseURL(environment: environment)
    }

    init(auth: CloudAuth, local: DaemonService?, approvalHolds: CloudApprovalHolds? = nil, appActive: @escaping @MainActor () -> Bool) {
        (self.auth, self.approvalHolds, self.appActive) = (auth, approvalHolds, appActive)
        apiBaseURL = Self.apiBaseURL(auth: auth)
        daemon = FeedDaemonClient(connection: { [weak local] in local?.connection })
        guard let local else { return }
        follow(local)
        observePresence()
    }

    /// Hands the local daemon's `feed-view-changed` events to the client, and a new connection that
    /// serves the feed as a change of everything (a reconnect lost the events meanwhile).
    private func follow(_ local: DaemonService) {
        let daemon = daemon
        local.store.sideEvents.subscribe { event in
            guard case .unknown(name: FeedDaemonClient.changedEvent, let payload) = event else { return }
            daemon.deliver(FeedDaemonClient.change(payload))
        }
        // task-owner: FeedService.tasks: follows the local daemon's connection; lives with the service.
        tasks.append(Task { [weak self, weak local] in
            for await serving in ObservationStream({ ObservationTrigger(local?.supports(FeedDaemonClient.capability) == true ? local?.connection.map(ObjectIdentifier.init) : nil) }) {
                guard let self, serving.value != nil else { continue }
                daemon.setPresence(active: appActive())
                daemon.restore() // a new daemon starts with the poller off and no update cards
                daemon.deliver(FeedDaemonClient.Change(changed: nil))
                self.readClosedHolds()
            }
        })
        daemon.observe { [weak self] change in
            guard let ids = change.changed, !ids.isEmpty else { return }
            self?.readHolds(ids)
        }
    }

    /// Presence for the owner's push rule: active while the app is active and
    /// the screen is awake and unlocked; events only, no heartbeat.
    private func observePresence() {
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let update: @MainActor (Bool?) -> Void = { [weak self] forced in
            guard let self else { return }
            daemon.setPresence(active: forced ?? self.appActive())
        }
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ forced: Bool?) -> MainActorObservation {
            MainActorObservation(name, center: center) { update(forced) }
        }
        observers = [
            on(app, NSApplication.didBecomeActiveNotification, true),
            on(app, NSApplication.didResignActiveNotification, false),
            on(workspace, NSWorkspace.screensDidSleepNotification, false),
            on(workspace, NSWorkspace.sessionDidResignActiveNotification, false),
            on(workspace, NSWorkspace.willSleepNotification, false),
            on(workspace, NSWorkspace.didWakeNotification, nil),
            on(workspace, NSWorkspace.screensDidWakeNotification, nil),
            on(workspace, NSWorkspace.sessionDidBecomeActiveNotification, nil),
        ]
    }

    /// The closed Cloud holds the owner already has (a launch, a reconnect).
    private func readClosedHolds() {
        guard let approvalHolds else { return }
        // task-owner: one daemon read; it records what it read and ends.
        Task { [daemon] in
            guard let items = try? await daemon.list(state: "closed", home: "cloud") else { return }
            approvalHolds.recordAnswered(items.lazy.filter(\.isClosed).compactMap(\.cloudHold))
        }
    }

    /// The changed items' owner state: a Cloud hold the owner closed.
    private func readHolds(_ ids: [String]) {
        guard let approvalHolds else { return }
        // task-owner: one daemon read; it records what it read and ends.
        Task { [daemon] in
            guard let items = try? await daemon.items(ids, confirmed: true) else { return }
            approvalHolds.recordAnswered(items.lazy.filter(\.isClosed).compactMap(\.cloudHold))
        }
    }

    var isSignedIn: Bool { auth.isSignedIn }

    /// Posts an installed update's card (cmux or an agent CLI) through the daemon's integration
    /// owner, never a cloud session; the owner's dedupe keeps one card per version. A card no daemon
    /// took stays pending until one does.
    func post(update card: UpdateFeedCard) {
        daemon.keepPosting(item: card.item, key: card.dedupeKey)
    }

    /// Applies the user-owned GitHub connection setting to the daemon's poller.
    func configureGitHub(enabled: Bool, pollIntervalSeconds: Double) {
        daemon.configureGitHub(enabled: enabled, intervalSeconds: pollIntervalSeconds)
    }

    /// Waits until the owner reports the item closed, or the deadline passes; the owner's item.
    @discardableResult
    func waitClosed(_ id: String, until deadline: ContinuousClock.Instant) async -> FeedDaemonItem? {
        await daemon.waitClosed(id, until: deadline)
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        observers = []
    }

    /// One HTTP call to the API Worker as the signed-in user (`/v1/ops` or `/v1/read`), in its
    /// personal team or in `team` (`x-cmux-team`; TeamDO confirms the membership).
    func call(_ path: String, _ body: [String: Any], team: String? = nil) async throws -> [String: Any] {
        guard auth.isSignedIn else { throw FeedServiceError.signedOut }
        var request = URLRequest(url: apiBaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(try await auth.tokens().access)", forHTTPHeaderField: "authorization")
        if let team { request.setValue(team, forHTTPHeaderField: "x-cmux-team") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // The bearer never goes through the shared, caching session.
        let (data, _) = try await CloudAPIClient.noStoreTransport.data(for: request)
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FeedServiceError.badReply }
        if let error = reply["error"] as? [String: Any] {
            throw FeedServiceError.owner(code: error["code"] as? String ?? "error", message: error["message"] as? String ?? "")
        }
        return reply
    }
}
