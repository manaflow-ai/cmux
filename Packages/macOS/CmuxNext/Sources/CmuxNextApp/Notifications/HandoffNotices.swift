import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextSettings

/// The native notification of a chat handed off to a Cloud machine (cloud work mode; the hand-off
/// store, cmux#26578): a hand-off lasts the whole session and counts turns (hq#4706). When a turn
/// is done, failed, or stops for the person (`needs-you`), a banner titled with the chat says so,
/// once per turn and status, under the notification settings of agent events (the `agent` source).
/// Never for a cancel or for progress, and never while the person looks at that chat. Clicking the
/// banner shows the chat (`sessionId`).
///
/// The app-level owner of every hand-off's wait is a ``SandboxRunFollower`` on the hand-off source:
/// one `GET /v1/handoffs/:id/wait` long-poll each (held up to 25 s; there is no push). At each sign-in
/// it follows the person's unfinished hand-offs from `GET /v1/handoffs`; ``watch(handoff:session:host:)``
/// adds one this app just made. Stop conditions: a hand-off's poll ends when it is closed (a turn's
/// end is not its end), at sign-out, when the store no longer shows it (403, 404) or after three days
/// without a change while no turn runs; ``stop()`` ends them all and the account observer. The list
/// call ends at sign-out, at another account's sign-in and when Cloud is turned off.
@MainActor
final class HandoffNotices {
    static let bannerPrefix = "handoff."
    let follower: SandboxRunFollower
    private weak var services: AppServices?
    private let list: @Sendable () async throws -> [CloudHandoff]
    /// The user whose hand-offs are followed now (``user(in:)``; tests pass their own).
    private let currentUser: @MainActor @Sendable () -> String?
    private var account: Task<Void, Never>?
    /// The list call of the user signed in, if one is out.
    private(set) var listing: Task<Void, Never>?

    init(services: AppServices, follower: SandboxRunFollower? = nil, list: (@Sendable () async throws -> [CloudHandoff])? = nil,
         user: (@MainActor @Sendable () -> String?)? = nil) {
        self.services = services
        self.currentUser = user ?? { [weak services] in services.flatMap(HandoffNotices.user(in:)) }
        let cloud = services.cloud, auth = cloud.auth, identity = cloud.installIdentity
        let owner = CloudOwnerAPIClient(
            baseURL: FeedService.apiBaseURL(auth: auth),
            accessToken: { try await auth.tokens().access },
            teamID: { (try? await identity.installToken()).flatMap(MacInstallIdentity.team(ofToken:)) }
        )
        self.follower = follower ?? SandboxRunFollower(source: .handoffs(wait: { id, after in try await owner.handoffWait(id, after: after) }))
        self.list = list ?? { try await owner.handoffs() }
        self.follower.onEnd = { [weak self] end in self?.told(end) }
        self.follower.onForget = { [weak services] ids in services?.notifications.desktop.withdraw(ids.map { Self.bannerPrefix + $0 }) }
    }

    /// Follows the signed-in account while Cloud may be called: its hand-offs resume, a sign-out
    /// stops them. Not gated on Labs: only a hand-off made (behind Labs) has anything to follow, and
    /// turning Labs off must not forget which stops were already told.
    func start() {
        guard account == nil else { return }
        let currentUser = currentUser
        account = Task { [weak self] in // task-owner: in `account`, cancelled in stop()
            for await user in ObservationStream({ currentUser() }) { self?.followAccount(user) }
        }
    }

    /// The followed user is now `user` (nil: signed out, or Cloud off): the list call of the one
    /// before ends, then `user`'s hand-offs resume.
    func followAccount(_ user: String?) {
        listing?.cancel()
        listing = nil
        follower.account(user)
        if let user { resume(for: user) }
    }

    func stop() {
        account?.cancel()
        account = nil
        listing?.cancel()
        listing = nil
        follower.stop()
    }

    /// The signed-in user whose hand-offs are followed; nil while Cloud is off.
    private static func user(in services: AppServices) -> String? {
        guard !services.registry.disabledFeatures.contains(.cloud), services.cloud.mayCallCloud, services.cloud.isSignedIn else { return nil }
        return services.cloud.auth.user?.id
    }

    /// Follows `user`'s unfinished hand-offs this app doesn't follow yet, and dates the ones it does
    /// from the list's last change (one list call per sign-in; where the store isn't deployed it
    /// answers 404 and nothing is followed). An answer that comes
    /// after `user` signed out, another signed in or Cloud was turned off follows nothing.
    private func resume(for user: String) {
        let list = list
        listing = Task { [weak self] in // task-owner: in `listing`, cancelled at sign-out, the next sign-in, Cloud off and stop()
            guard let handoffs = try? await list(), !Task.isCancelled, let self, self.currentUser() == user else { return }
            let seen = Date()
            for handoff in handoffs where handoff.isOpen {
                if !self.follower.knows(handoff.id) {
                    self.follower.watch(Self.listed(handoff, user: user, seen: seen))
                } else if let updatedAt = handoff.updatedAt {
                    // Followed since before (a record saved at an earlier launch): it ages from the list's last change.
                    self.follower.refresh(handoff.id, changed: Date(timeIntervalSince1970: updatedAt / 1_000), running: handoff.isRunning)
                }
            }
        }
    }

    /// Follows hand-off `id` of chat `session`, which this app just made; `host` is the session's
    /// acpmux host, where a click opens it when no tab shows it.
    func watch(handoff id: String, session: String, host: String?) {
        guard let user = currentUser() else { return }
        let handoff = CloudHandoff(id: id, sessionId: session, status: "starting", summary: nil, createdAt: Date().timeIntervalSince1970 * 1_000, version: nil)
        follower.watch(Self.record(handoff, user: user, host: host))
    }

    /// The record of a hand-off found in the person's list at `seen`: followed from where the list
    /// shows it, so its current state is no news (only what changes after is told). Its three days
    /// count from its last change (else from `seen`), never from its creation: a session made long
    /// ago may be in a turn now.
    static func listed(_ handoff: CloudHandoff, user: String, seen: Date = Date()) -> SandboxRunRecord {
        var record = record(handoff, user: user, host: nil)
        record.cursor = handoff.version
        record.told = CloudHandoff.notice(status: handoff.status, turn: handoff.turn).map { [$0.key] }
        record.changed = handoff.updatedAt.map { Date(timeIntervalSince1970: $0 / 1_000) } ?? seen
        return record
    }

    /// The follower's record of `handoff`: its chat is the record's key. A turn that runs is never
    /// given up for age.
    static func record(_ handoff: CloudHandoff, user: String, host: String?) -> SandboxRunRecord {
        var record = SandboxRunRecord(id: handoff.id, task: handoff.summary ?? "", key: handoff.sessionId, user: user, team: nil,
                                      started: Date(timeIntervalSince1970: handoff.createdAt / 1_000))
        record.host = host
        record.running = handoff.isRunning ? true : nil
        return record
    }

    private func told(_ end: SandboxRunEnd) {
        guard end.replayed, let desktop = services?.notifications.desktop else { return post(end) }
        // An end told again after a crash: its banner may already be in Notification Center.
        // task-owner: one read of the delivered banners for this replayed end
        Task { @MainActor [weak self] in
            if await desktop.isDelivered(Self.bannerPrefix + end.record.id) { return }
            self?.post(end)
        }
    }

    /// The banner, by the agent source's rules (`desktop`, quiet hours, sounds, Dock bounce). None
    /// while the person looks at the chat: it shows the change itself.
    private func post(_ end: SandboxRunEnd) {
        guard let center = services?.notifications else { return }
        let tab = tab(showing: end.record.key)
        if let tab, center.isViewed(tab) { return center.note("handoff \(end.record.id) \(end.outcome.rawValue) viewed") }
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.appActive = services?.appActiveSource() ?? false
        arrival.soundEvent = end.outcome == .succeeded ? .finished : end.outcome == .needsYou ? .message : .error
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        arrival.minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        var decision = NotificationPolicy(prefs: center.preferences).decide(arrival)
        center.note("handoff \(end.record.id) \(end.outcome.rawValue) \(decision)")
        guard !decision.acknowledge, center.desktopPostingEnabled else { return }
        center.soundGate.admit(&decision, cooldownSeconds: center.preferences.sounds.cooldownSeconds)
        let chat = tab.flatMap { services?.locateTabOnAnyMachine($0)?.0.title }
        let text = Self.text(end, chat: chat)
        if decision.desktop {
            // One banner per hand-off: its end replaces the needs-you banner it posted before.
            center.desktop.post(id: Self.bannerPrefix + end.record.id, title: text.title, body: text.body, surface: nil,
                                workspace: nil, defaultSound: decision.sound == "default")
            if let sound = decision.sound, sound != "default" { center.soundGate.player.play(sound, volume: decision.soundVolume, banner: true) }
        } else if let sound = decision.sound {
            center.soundGate.player.play(sound, volume: decision.soundVolume, banner: false)
        }
        if let mode = decision.bounce { center.dockAttention.bounce(untilActive: mode == .untilActive) }
    }

    /// The banner's words: the chat's title (else the summary's first line), then what happened and,
    /// once it finished, the summary.
    static func text(_ end: SandboxRunEnd, chat: String?) -> (title: String, body: String) {
        let summary = summary(end.snapshot) ?? end.record.task
        let firstLine = summary.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let named = chat.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? firstLine
        let line = named ?? String(localized: "handoffs.notification.untitled", defaultValue: "Cloud task", table: "Handoffs", bundle: .module)
        let title = line.count > 120 ? String(line.prefix(119)) + "…" : line
        let state = switch end.outcome {
        case .needsYou: String(localized: "handoffs.notification.needsYou", defaultValue: "Needs you", table: "Handoffs", bundle: .module)
        case .succeeded: String(localized: "handoffs.notification.done", defaultValue: "Done", table: "Handoffs", bundle: .module)
        case .failed, .timedOut, .cancelled: String(localized: "handoffs.notification.failed", defaultValue: "Failed", table: "Handoffs", bundle: .module)
        }
        let detail = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = end.outcome == .needsYou || detail.isEmpty || named == firstLine ? state : state + "\n" + String(detail.prefix(240))
        return (title, body)
    }

    /// The hand-off's summary in a wait's `{handoff}` (nil: none, or a replayed end, which keeps no body).
    static func summary(_ data: Data) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (object?["handoff"] as? [String: Any])?["summary"] as? String
    }

    /// A click on banner `banner`: the tab showing the chat, else a new workspace on the session's
    /// host when this app made the hand-off. False when the banner is no hand-off's.
    @discardableResult
    func open(banner: String) -> Bool {
        guard banner.hasPrefix(Self.bannerPrefix), let services else { return false }
        follower.forgetOld()
        let id = String(banner.dropFirst(Self.bannerPrefix.count))
        guard let record = follower.endedRun(id)?.record ?? follower.following.first(where: { $0.id == id }) else { return true }
        if let tab = tab(showing: record.key), services.revealTab(tab) { return true }
        // A hand-off found in the list names no host this app knows: the chat stays where it is, and
        // the app comes forward. (The composer's hand-off passes its host to watch(handoff:session:host:).)
        guard let host = record.host else {
            NSApp.activate()
            return true
        }
        do {
            services.registry.track(try AgentSessionWorkspace.open(session: record.key, name: nil, cwd: nil, host: host, services: services))
        } catch {
            services.notifications.note("handoff \(id) open: \(error)")
        }
        return true
    }

    /// The agent tab showing chat `session`, on this Mac or any machine the app reaches.
    private func tab(showing session: String) -> String? {
        guard let tabs = services?.agentTabs else { return nil }
        return tabs.listTabs().first { (tabs.sessions[$0.key] ?? $0.record.session) == session }?.key
            ?? AgentPriorityChats.app.remoteTab(showing: session)
    }
}
