import AppKit
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
    private var account: Task<Void, Never>?

    init(services: AppServices, follower: SandboxRunFollower? = nil) {
        self.services = services
        self.follower = follower ?? SandboxRunFollower(wait: { [api = services.cloud.api] id, team in
            try await api.pinningTeam(team).waitRun(id, timeoutMs: 10_000)
        })
        self.follower.onEnd = { [weak self] end in self?.ended(end) }
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

    /// A send's Run `id`, followed here; answers its terminal snapshot.
    func follow(id: String, task: String, key: String, team: String?) async throws -> Data {
        guard let user = services?.cloud.auth.user?.id else { throw CloudAPIError.notSignedIn }
        return try await follower.follow(SandboxRunRecord(id: id, task: task, key: key, user: user, team: team, started: Date()))
    }

    func ended(_ end: SandboxRunEnd) {
        post(end)
    }

    /// The banner, by the agent source's rules (`desktop`, quiet hours, sounds, Dock bounce). A Run
    /// whose tab the person is looking at posts none: its card shows the end.
    private func post(_ end: SandboxRunEnd) {
        guard let center = services?.notifications else { return }
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.appActive = NSApp.isActive
        arrival.paneIsViewed = tab(holding: end.record.key).map { center.isViewed($0) } ?? false
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
                                workspace: nil, defaultSound: decision.sound == "default")
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
        }
        return (title, body)
    }

    /// A click on banner `banner`: the tab that sent the Run, else a new tab showing its card.
    /// False when the banner is no Run's.
    @discardableResult
    func open(banner: String) -> Bool {
        guard banner.hasPrefix(Self.bannerPrefix) else { return false }
        // The follower keeps the ended Runs (bounded) across a relaunch, so a banner left in
        // Notification Center still opens its card.
        guard let services, let run = follower.endedRun(String(banner.dropFirst(Self.bannerPrefix.count))) else { return true }
        if let key = tab(holding: run.key), let tab = NotificationCenterService.tab(id: key, in: services.daemon.store) {
            services.notifications.open(surface: tab.surface)
            return true
        }
        let card = run.card.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let seed = AgentPaneSeedSource(AgentPaneSeed())
        seed.sandboxResult = (run.task, run.key, card)
        services.windows.active?.focusedPane?.newTabPage(seed: seed)
        return true
    }

    /// The agent tab whose page holds the send of attempt `key`.
    private func tab(holding key: String) -> String? {
        services?.agentTabs.views.first { $0.value.model.sandboxRuns.holds(key: key) }?.key
    }
}
