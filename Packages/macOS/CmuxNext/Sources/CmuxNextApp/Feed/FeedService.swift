import AppKit
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextFeed
import Foundation

/// The app's feed (plans/cmux-next/feed.md): one `FeedModel` mirroring the
/// user's `FeedDO` through `CloudFeedSource`. It starts once the cmux account
/// is signed in (the Stack session token is the bearer until install tokens
/// exist) and reports the app's active state as presence for the owner's
/// push rule. View state (panel, selection, drafts) stays in this client.
/// It also serves `feed.request` for local hook adapters: post, then wait for
/// the owner's closed state in the mirror.
@MainActor
final class FeedService {
    let model: FeedModel
    let apiBaseURL: URL
    private let source: CloudFeedSource
    private let localOwner: LocalFeedSourceAdapter
    private let github: GitHubFeedSource
    private let showcase: Bool
    private let auth: CloudAuth
    /// The app's acpmux, resolved once at startup (nil: a mock agent host or no acpmux binary).
    /// A report reply uses it as is: the reply path resolves nothing (no executable or signature
    /// check on the main thread).
    let acpmuxEnvironment: AcpmuxEnvironment?
    /// The reports reader; a page of a reader that a reset stopped is dropped.
    private let reports = AcpmuxMailboxSubscription()
    /// Wakes the current reports reader's retry wait (one per reader, so a stopped reader's end
    /// never touches the next one's watch): its socket's changes, and app activation or wake.
    private var reportsWake: RetryWake?
    private var reportRows: [String: FeedReport] = [:]
    private var started = false
    /// The account the mirror belongs to; a sign-out or another account resets it.
    private var account: String?
    private var observers: [MainActorObservation] = []
    private var accountWatch: Task<Void, Never>?
    private(set) var connection: FeedConnection = .disconnected("not started")
    /// Owner-confirmed state of each item (never the overlay).
    private var confirmed: [String: FeedItemState] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Told every owner-confirmed item (snapshot and events), never the overlay
    /// (the agent permission feed bridge reads answers here).
    var onConfirmedItems: (@MainActor ([FeedItem]) -> Void)?

    /// The API Worker for this build: `CMUX_NEXT_FEED_API_URL`, else staging
    /// for development auth and production for production auth.
    static func apiBaseURL(auth: CloudAuth, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        auth.configuration.ownerAPIBaseURL(environment: environment)
    }

    init(auth: CloudAuth, showcase: Bool = false, acpmuxEnvironment: AcpmuxEnvironment? = nil) {
        self.auth = auth
        self.showcase = showcase
        self.acpmuxEnvironment = acpmuxEnvironment
        apiBaseURL = Self.apiBaseURL(auth: auth)
        // The answer's device label is the owner's record (the install); this name is only the overlay's.
        source = CloudFeedSource(apiBaseURL: apiBaseURL, device: "Mac") { [auth] in
            try await auth.tokens().access
        }
        var observe: (@MainActor (FeedSourceEvent) -> Void)?
        localOwner = LocalFeedSourceAdapter(primary: showcase ? MockFeedSource() : source)
        github = GitHubFeedSource(owner: localOwner)
        model = FeedModel(source: FeedTeeSource(localOwner) { observe?($0) })
        model.githubDetail = { [weak self] item in self?.githubDetail(for: item) }
        observe = { [weak self] in self?.observe($0) }
        model.onRefresh = nil
        observePresence()
        // task-owner: FeedService.accountWatch: follows sign-in, sign-out and account switches; lives with the service.
        accountWatch = Task { [weak self] in
            await auth.awaitRestored()
            for await signedIn in ObservationStream({ auth.isSignedIn ? (auth.user?.id ?? "") : nil }) {
                self?.accountChanged(signedIn)
            }
        }
    }

    /// Presence for the owner's push rule: active while the app is active and
    /// the screen is awake and unlocked; events only, no heartbeat.
    private func observePresence() {
        let app = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let update: @MainActor (Bool?) -> Void = { [weak self] forced in
            guard let self else { return }
            source.setPresence(active: forced ?? NSApp.isActive)
            if forced == nil { source.checkAlive() }
            // An activation or wake may find acpmux back: a reports reader past its timed retries tries again.
            if forced != false { reportsWake?.fire() }
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
            // After a wake the socket may be dead without an error: probe it.
            on(workspace, NSWorkspace.didWakeNotification, nil),
            on(workspace, NSWorkspace.screensDidWakeNotification, nil),
            on(workspace, NSWorkspace.sessionDidBecomeActiveNotification, nil),
        ]
    }

    /// A new sign-in state: start for this account, or reset (sign-out, another account).
    private func accountChanged(_ user: String?) {
        guard user != account else { return }
        if account != nil {
            source.reset(reason: "signed out")
            github.resetDetails()
            resetReports()
            started = false
        }
        account = user
        if user != nil, started { localOwner.reconnectPrimary() }
        startIfSignedIn()
    }

    /// Starts the mirror when signed in; the panel and requests call it again (after a sign-in).
    func startIfSignedIn() {
        guard !started else {
            if auth.isSignedIn {
                startReportsIfNeeded()
                source.setPresence(active: NSApp.isActive)
            }
            return
        }
        account = auth.user?.id
        started = true
        model.start()
        startReportsIfNeeded()
        if auth.isSignedIn { source.setPresence(active: NSApp.isActive) }
    }

    var isSignedIn: Bool { auth.isSignedIn }

    /// Posts an installed update's card (cmux or an agent CLI) through the local owner, never a
    /// cloud session; the owner's dedupe keeps one card per version.
    func post(update card: UpdateFeedCard) {
        localOwner.post(card.item)
    }

    /// Live GitHub details are held by the source only while the app runs.
    func githubDetail(for id: String) -> GitHubFeedDetail? { github.githubDetail(for: id) }

    /// Cloud owners assign the final feed id. Resolve the source's in-memory
    /// detail by URL when that id differs from the poster's provisional id.
    func githubDetail(for item: FeedItem) -> GitHubFeedDetail? {
        github.githubDetail(for: item.id)
            ?? item.context.url.flatMap { url in github.githubDetails.values.first { $0.url == url } }
    }

    func stop() {
        accountWatch?.cancel()
        resetReports()
        model.stop()
        github.stop()
        github.resetDetails()
        started = false
    }

    /// Applies the user-owned GitHub connection setting. The source remains
        /// stopped until the feed owner is running and the user is signed in.
    func configureGitHub(enabled: Bool, pollIntervalSeconds: Double) {
        githubEnabled = enabled
        model.githubConnectionEnabled = enabled
        if enabled {
            model.onRefresh = { [weak self] in
                guard let self, self.connection == .connected else { return }
                // task-owner: one-shot manual refresh; the source's in-flight guard owns duplicate suppression.
                Task { @MainActor in await self.github.refresh() }
            }
        } else {
            model.onRefresh = nil
        }
        github.setInterval(.seconds(pollIntervalSeconds))
        if enabled {
            startIfSignedIn()
            if connection == .connected { github.start() }
        } else {
            github.stop()
        }
    }

    private var githubEnabled = false

    /// The signed-in account owns its own local alias. Using the stable auth
    /// id keeps a second account from reading Leo's reports mailbox.
    private var reportsRecipient: String? {
        guard let person = auth.user?.id.trimmingCharacters(in: .whitespacesAndNewlines), !person.isEmpty else {
            return nil
        }
        return "reports:\(person)"
    }

    private func resetReports() {
        reports.stop()
        reportsWake = nil
        reportRows.removeAll()
        model.replaceReports([])
    }

    /// Reads the quiet reports alias without creating a model attachment. The
    /// mailbox wait is event-driven; quiet delivery notifies this reader but
    /// never wakes the sender's ACP turn. The reader runs off the main actor and
    /// retries on the shared daemon-client path (`AcpmuxMailboxReader`): a
    /// missing socket waits for its file-system event, a refusing one is paced.
    private func startReportsIfNeeded() {
        guard auth.isSignedIn, !reports.isRunning, let socketPath = acpmuxEnvironment?.socketPath,
              let reportsRecipient else { return }
        let wake = RetryWake(owner: "feed.reports.retry")
        reportsWake = wake
        let reader = AcpmuxMailboxReader(socketPath: socketPath, recipient: reportsRecipient, wake: wake)
        // Stopped by resetReports (sign-out, another account, stop); a page already on its way is dropped.
        reports.start(reader) { [weak self] page in self?.applyReports(page) }
    }

    private func applyReports(_ page: AcpmuxMailboxPage) {
        for message in page.messages {
            reportRows[message.id] = FeedReport(
                id: message.id,
                sender: message.sender,
                body: message.body,
                createdAt: message.createdAt
            )
        }
        model.replaceReports(Array(reportRows.values))
    }

    private func observe(_ event: FeedSourceEvent) {
        switch event {
        case let .connection(state):
            connection = state
            if state == .connected, githubEnabled { github.start() }
            if case .disconnected = state {
                github.stop()
                github.resetConditionalRequests()
            }
        case let .snapshot(snapshot):
            confirmed = Dictionary(snapshot.items.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
            resumeClosed()
            onConfirmedItems?(snapshot.items)
        case let .event(event):
            switch event.change {
            case let .items(items):
                for item in items { confirmed[item.id] = item.state }
                onConfirmedItems?(items)
            case let .remove(ids): for id in ids { confirmed[id] = nil }
            }
            resumeClosed()
        case .settled: break
        }
    }

    private func resumeClosed() {
        for (id, list) in waiters where confirmed[id].map({ $0 != .open }) ?? false {
            waiters[id] = nil
            for waiter in list { waiter.resume() }
        }
    }

    /// Waits until the owner reports the item closed, or the deadline passes.
    func waitClosed(_ id: String, until deadline: ContinuousClock.Instant) async {
        if confirmed[id].map({ $0 != .open }) ?? false { return }
        // task-owner: FeedService.waitClosed, one-shot request deadline; resumes this waiter only.
        let timer = Task { [weak self] in
            // wakeup-allow: one-shot deadline of one feed request (at most 120 s), cancelled when the item closes.
            try? await ContinuousClock().sleep(until: deadline)
            self?.expireWaiters(id)
        }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
        timer.cancel()
    }

    private func expireWaiters(_ id: String) {
        guard let list = waiters.removeValue(forKey: id) else { return }
        for waiter in list { waiter.resume() }
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

enum FeedServiceError: Error {
    case signedOut
    case badReply
    case owner(code: String, message: String)
}
