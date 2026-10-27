import AppKit
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextFeed
import CmuxNextWakeups
import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

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
    /// The app's deadline placer, for each request's wait (``waitClosed(_:until:)``).
    private let deadlines: MainDeadlineScheduler
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
    private var observers: [EventSubscription] = []
    /// Follows sign-in, sign-out and account switches once the session restore finished.
    private var accountWatch: ServiceObservation<String?>?
    /// ``stop()`` ended the account watch for good (also one whose restore wait had not replied yet).
    private var accountWatchEnded = false
    /// The off-main start of the account watch and the person's manual GitHub refresh.
    private let work: BackgroundWork
    private(set) var connection: FeedConnection = .disconnected("not started")
    /// Owner-confirmed state of each item (never the overlay).
    private var confirmed: [String: FeedItemState] = [:]
    private var waiters: [String: [OnceContinuation<Void, OnceContinuationError>]] = [:]
    /// Told every owner-confirmed item (snapshot and events), never the overlay
    /// (the agent permission feed bridge reads answers here).
    var onConfirmedItems: (@MainActor ([FeedItem]) -> Void)?

    /// The API Worker for this build: `CMUX_NEXT_FEED_API_URL`, else staging
    /// for development auth and production for production auth.
    static func apiBaseURL(auth: CloudAuth, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        auth.configuration.ownerAPIBaseURL(environment: environment)
    }

    /// `energy` stretches the GitHub poll under Energy Saver; with `shown`, it books nothing while no window shows,
    /// and `appNode` (the app's visibility node) aligns its booked refresh while the app is hidden.
    /// `appEvents` and `workspaceEvents` are the app's one fan-out of the NSApp and NSWorkspace notices.
    init(auth: CloudAuth, deadlines: MainDeadlineScheduler, work: BackgroundWork, appEvents: AppEvents, workspaceEvents: AppEvents,
         energy: EnergyPolicySource, shown: ShownWindows?, appNode: VisibilityNode?, showcase: Bool = false,
         acpmuxEnvironment: AcpmuxEnvironment? = nil) {
        self.auth = auth
        self.deadlines = deadlines
        self.work = work
        self.showcase = showcase
        self.acpmuxEnvironment = acpmuxEnvironment
        apiBaseURL = Self.apiBaseURL(auth: auth)
        // The answer's device label is the owner's record (the install); this name is only the overlay's.
        source = CloudFeedSource(apiBaseURL: apiBaseURL, device: "Mac", energy: energy, mainWork: deadlines.work) { [auth] in
            try await auth.tokens().access
        }
        var observe: (@MainActor (FeedSourceEvent) -> Void)?
        localOwner = LocalFeedSourceAdapter(primary: showcase ? MockFeedSource() : source)
        github = GitHubFeedSource(owner: localOwner, energy: energy, shown: shown, deadlines: deadlines, appNode: appNode)
        model = FeedModel(source: FeedTeeSource(localOwner) { observe?($0) })
        model.githubDetail = { [weak self] item in self?.githubDetail(for: item) }
        observe = { [weak self] in self?.observe($0) }
        model.onRefresh = nil
        observePresence(app: appEvents, workspace: workspaceEvents)
        // task-owner: the session restore's wait, off main; the account watch starts in its reply and lives with the service.
        let mainWork = deadlines.work
        work.task(.bestEffort) { [weak self] in
            await auth.awaitRestored()
            mainWork.postFromAnyThread(.background, owner: "FeedService.accountWatch") { [weak self] in self?.followAccount() }
        }
    }

    /// Follows the signed-in account (a model change, so a service observation: it must run while no window shows).
    /// A person's sign-in flushes in their input response; a token refresh or a remote sign-out is background work.
    private func followAccount() {
        guard accountWatch == nil, !accountWatchEnded else { return }
        let auth = auth
        accountWatch = ServiceObservation(.background, owner: "FeedService.account", on: deadlines.work) {
            auth.isSignedIn ? (auth.user?.id ?? "") : nil
        } apply: { [weak self] user in
            self?.accountChanged(user)
        }
    }

    /// Presence for the owner's push rule: active while the app is active and
    /// the screen is awake and unlocked; events only, no heartbeat. Through the app's one
    /// observer per notice (`AppEvents`); presence is reported whatever shows.
    private func observePresence(app: AppEvents, workspace: AppEvents) {
        let update: @MainActor (Bool?) -> Void = { [weak self] forced in
            guard let self else { return }
            source.setPresence(active: forced ?? NSApp.isActive)
            if forced == nil { source.checkAlive() }
            // An activation or wake may find acpmux back: a reports reader past its timed retries tries again.
            if forced != false { reportsWake?.fire() }
        }
        let owner = "FeedService.presence"
        observers = [
            app.subscribe(NSApplication.didBecomeActiveNotification, owner: owner) { update(true) },
            app.subscribe(NSApplication.didResignActiveNotification, owner: owner) { update(false) },
            workspace.subscribe(NSWorkspace.screensDidSleepNotification, owner: owner) { update(false) },
            workspace.subscribe(NSWorkspace.sessionDidResignActiveNotification, owner: owner) { update(false) },
            workspace.subscribe(NSWorkspace.willSleepNotification, owner: owner) { update(false) },
            // After a wake the socket may be dead without an error: probe it.
            workspace.subscribe(NSWorkspace.didWakeNotification, owner: owner) { update(nil) },
            workspace.subscribe(NSWorkspace.screensDidWakeNotification, owner: owner) { update(nil) },
            workspace.subscribe(NSWorkspace.sessionDidBecomeActiveNotification, owner: owner) { update(nil) },
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
        accountWatchEnded = true
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
                // task-owner: one-shot manual refresh, the rest of the person's click; the source's in-flight guard owns
                // duplicate suppression.
                self.work.task(.userBlocking) { [github = self.github] in await github.refresh() }
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
            for waiter in list { waiter.resume(returning: ()) }
        }
    }

    /// Waits until the owner reports the item closed, or the deadline passes.
    func waitClosed(_ id: String, until deadline: ContinuousClock.Instant) async {
        if confirmed[id].map({ $0 != .open }) ?? false { return }
        // The request's deadline (at most 120 s): a CLI request waits on it; cancelled when the item closes first.
        let timer = MainDeadline(owner: "FeedService.waitClosed", workClass: .automation, scheduler: deadlines)
        timer.schedule(after: ContinuousClock.now.duration(to: deadline)) { [weak self] in self?.expireWaiters(id) }
        // A service dropped with the call waiting ends it abandoned, as the deadline would.
        _ = try? await withOnceContinuation { (waiter: OnceContinuation<Void, OnceContinuationError>) in waiters[id, default: []].append(waiter) }
        timer.cancel()
    }

    private func expireWaiters(_ id: String) {
        guard let list = waiters.removeValue(forKey: id) else { return }
        for waiter in list { waiter.resume(returning: ()) }
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
        guard let reply = try JSONSerialization.blockingJSONObject(with: data) as? [String: Any] else { throw FeedServiceError.badReply }
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
