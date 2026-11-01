import AppKit
import CmuxNextActions
import CmuxNextAppCore
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextSettings

/// The native notification of a sandboxed Run handed off from a New Tab page (hq#3367): when the Run
/// succeeds, fails or is cancelled, a banner titled with the task's first line says how it ended,
/// under the notification settings of agent events (`notifications.*`, the `agent` source). A Run
/// this app cancelled tells nothing. Clicking the banner shows the Run's card: in the tab that sent
/// it, or, once that tab closed, in a new tab.
///
/// The app-level owner of every Run's wait is ``SandboxRunFollower``: it lives as long as the app,
/// resumes the Runs still in flight at launch, and stops when the Run ends or the person signs out
/// (``start()``'s account observer, cancelled in ``stop()``).
@MainActor
final class SandboxRunNotices {
    static let bannerPrefix = "sandbox-run."
    let follower: SandboxRunFollower
    private weak var services: AppServices?
    /// The signed-in user whose Runs are followed (tests pass their own).
    private let currentUser: @MainActor () -> String?
    private var account: Task<Void, Never>?

    init(services: AppServices, follower: SandboxRunFollower? = nil, user: (@MainActor () -> String?)? = nil) {
        self.services = services
        self.currentUser = user ?? { [weak services] in services?.cloud.auth.user?.id }
        self.follower = follower ?? SandboxRunFollower(wait: { [api = services.cloud.api] id, team in
            try await api.pinningTeam(team).waitRun(id, timeoutMs: 10_000)
        })
        self.follower.onEnd = { [weak self] end in self?.ended(end) }
        // A card dropped after its week takes its banner with it: no banner is left that opens nothing.
        self.follower.onForget = { [weak services] ids in services?.notifications.desktop.withdraw(ids.map { Self.bannerPrefix + $0 }) }
    }

    /// Follows the signed-in account: its Runs resume, a sign-out stops them.
    func start() {
        guard account == nil, let cloud = services?.cloud else { return }
        let follower = follower
        account = Task { // task-owner: in `account`, cancelled in stop()
            for await user in ObservationStream({ cloud.isSignedIn ? cloud.auth.user?.id : nil }) { follower.account(user) }
        }
    }

    func stop() {
        account?.cancel()
        account = nil
        follower.stop()
    }

    /// A send's Run `id`, followed here for the account signed in now; answers its terminal snapshot.
    /// The server decides who may read it: if the create went out under another account (a switch
    /// during the send), this account's wait is refused (403, 404) and the follow ends, untold.
    func follow(id: String, task: String, key: String, team: String?, incognito _: Bool? = nil) async throws -> Data {
        guard let user = currentUser() else { throw CloudAPIError.timedOut("/api/runs/\(id)") }
        var record = SandboxRunRecord(id: id, task: task, key: key, user: user, team: team, started: Date())
        // A send whose tab is gone already may have been an incognito one: it is taken as one.
        record.incognito = tab(holding: key) == nil || incognito(key) ? true : nil
        return try await follower.follow(record)
    }

    func ended(_ end: SandboxRunEnd) {
        let snapshot = (try? JSONSerialization.jsonObject(with: end.snapshot)) as? [String: Any] ?? [:]
        for view in services.map({ Array($0.agentTabs.views.values) }) ?? [] { view.model.sandboxRuns.settle(key: end.record.key, snapshot: snapshot) }
        guard end.replayed else { return post(end) }
        // An end told again after a crash: its banner may already be in Notification Center. It is
        // marked told only after this, so a quit before leaves it to the next launch.
        let follower = follower
        // task-owner: one read of the delivered banners for this replayed end
        Task { @MainActor [weak self] in
            let delivered = await self?.services?.notifications.desktop.isDelivered(Self.bannerPrefix + end.record.id) ?? false
            if !delivered { self?.post(end) }
            follower.markTold(end.record.id)
        }
    }

    /// Whether the page of attempt `key`'s tab may still show an answer older than the Run's end.
    private func stale(_ key: String) -> Bool {
        services?.agentTabs.views.values.contains { $0.model.sandboxRuns.settledLate == key } ?? false
    }

    /// The banner, by the agent source's rules (`desktop`, quiet hours, sounds, Dock bounce). A Run
    /// whose tab the person is looking at posts none: its card shows the end.
    private func post(_ end: SandboxRunEnd) {
        guard let center = services?.notifications else { return }
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.appActive = services?.appActiveSource() ?? false
        // A tab whose page still shows the send's earlier answer doesn't show the end.
        arrival.paneIsViewed = !stale(end.record.key) && (tab(holding: end.record.key).map { center.isViewed($0) } ?? false)
        arrival.soundEvent = end.outcome == .succeeded ? .finished : end.outcome == .cancelled ? .message : .error
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        arrival.minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        var decision = NotificationPolicy(prefs: center.preferences).decide(arrival)
        center.note("sandbox run \(end.record.id) \(end.outcome.rawValue) \(decision)")
        guard !decision.acknowledge, center.desktopPostingEnabled else { return }
        center.soundGate.admit(&decision, cooldownSeconds: center.preferences.sounds.cooldownSeconds)
        let text = Self.text(end)
        if decision.desktop {
            center.desktop.post(id: Self.bannerPrefix + end.record.id, title: text.title, body: text.body, surface: nil,
                                workspace: nil, defaultSound: decision.sound == "default",
                                incognito: end.record.incognito == true || incognito(end.record.key))
            if let sound = decision.sound, sound != "default" { center.soundGate.player.play(sound, volume: decision.soundVolume, banner: true) }
        } else if let sound = decision.sound {
            center.soundGate.player.play(sound, volume: decision.soundVolume, banner: false)
        }
        if let mode = decision.bounce { center.dockAttention.bounce(untilActive: mode == .untilActive) }
    }

    /// The banner's words: the task's first line, then how the Run ended.
    static func text(_ end: SandboxRunEnd) -> (title: String, body: String) {
        let line = end.record.task.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let title = line.count > 120 ? String(line.prefix(119)) + "…" : line
        let body = switch end.outcome {
        case .succeeded: String(localized: "runs.notification.succeeded", defaultValue: "Run finished", table: "Runs", bundle: .module)
        case .failed: String(localized: "runs.notification.failed", defaultValue: "Run failed", table: "Runs", bundle: .module)
        case .timedOut: String(localized: "runs.notification.timedOut", defaultValue: "Run timed out", table: "Runs", bundle: .module)
        case .cancelled: String(localized: "runs.notification.cancelled", defaultValue: "Run cancelled", table: "Runs", bundle: .module)
        // A Run never stops for the person (only a hand-off does, HandoffNotices).
        case .needsYou: String(localized: "runs.notification.failed", defaultValue: "Run failed", table: "Runs", bundle: .module)
        }
        return (title, body)
    }

    /// A click on banner `banner`: the tab that sent the Run, else a new workspace whose chat shows
    /// its card, as Open Chat opens one (it opens a window when none is open).
    /// False when the banner is no Run's.
    @discardableResult
    func open(banner: String) -> Bool {
        guard banner.hasPrefix(Self.bannerPrefix) else { return false }
        // The follower keeps the ended Runs a week across a relaunch, so a banner left in Notification
        // Center still opens its card; an older one is withdrawn now, and opens nothing.
        follower.forgetOld()
        guard let services, let run = follower.endedRun(String(banner.dropFirst(Self.bannerPrefix.count))) else { return true }
        if !stale(run.record.key), let key = tab(holding: run.record.key), let tab = NotificationCenterService.tab(id: key, in: services.daemon.store) {
            services.notifications.open(surface: tab.surface)
            return true
        }
        // An incognito chat's Run never shows outside its window: with the tab gone, the click opens nothing.
        if run.record.incognito == true { return true }
        var seed = AgentPaneSeed()
        seed.sandboxResult = .init(task: run.record.task, key: run.record.key, card: run.card)
        var spawn = WorkspaceSpawn(name: Self.text(SandboxRunEnd(record: run.record, outcome: run.outcome, snapshot: Data())).title)
        spawn.firstChat = seed
        let windowID = services.windows.active?.state.id
        // task-owner: the registry tracks this one workspace create (ChatsOpenCoordinator's path)
        services.registry.track(Task { @MainActor in
            do {
                _ = try await services.windows.createWorkspace(spawn, into: windowID)
                return nil
            } catch {
                return ActionWorkFailure("open run", error)
            }
        })
        return true
    }

    /// Whether attempt `key`'s tab is in an incognito window.
    private func incognito(_ key: String) -> Bool {
        guard let services, let tab = tab(holding: key) else { return false }
        return services.cache.browserTabs.isIncognitoTab(services.agentTabs.resolve(tab))
    }

    /// The agent tab whose page holds the send of attempt `key`.
    private func tab(holding key: String) -> String? {
        services?.agentTabs.views.first { $0.value.model.sandboxRuns.holds(key: key) }?.key
    }
}
