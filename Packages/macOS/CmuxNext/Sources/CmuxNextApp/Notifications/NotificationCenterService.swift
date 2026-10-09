import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextWakeups
import Observation

/// Notifications in the app (plans/cmux-next/notifications.md). The daemon
/// owns every notification and its unread marker; this service reacts to
/// new ones (attention ring, banner, sound, timeout) and acknowledges them
/// through `ack-tab-notifications` when `NotificationPolicy` says an
/// interaction read them. Local daemon only; Cloud machines keep their
/// markers until opened or dismissed.
@MainActor
@Observable
final class NotificationCenterService {
    /// `notifications.*` from cmux.json (the mute action updates it at once).
    var preferences = NotificationPreferences()
    @ObservationIgnored weak var services: AppServices?
    @ObservationIgnored let desktop = DesktopNotifier()
    @ObservationIgnored private var lastKeystroke: [String: ContinuousClock.Instant] = [:]
    /// `timeout` dismissal deadlines per tab id (one-shot `DemandTimer`s).
    @ObservationIgnored private var timeouts: [String: DemandTimer] = [:]
    /// Banner ids posted per tab id, withdrawn once the tab is read.
    @ObservationIgnored private var banners: [String: [String]] = [:]
    @ObservationIgnored private var lastSeen: UInt64 = 0
    /// The Dock badge this service set last (nil: none).
    @ObservationIgnored var dockBadgeLabel: String?
    /// Mirrors arrivals into the feed (feed.md section 9, step 1); nil without a feed.
    @ObservationIgnored var feedBridge: FeedNotificationBridge?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// Recent arrivals and what was decided (for `debug.notifications`).
    @ObservationIgnored private(set) var log: [String] = []
    /// Showcase captures seed the real daemon ledger without showing banners
    /// or prompting for system authorization at launch.
    @ObservationIgnored var desktopPostingEnabled = true
    /// The deadline clock; tests inject their own.
    @ObservationIgnored var clock: any Clock<Duration> = ContinuousClock()
    /// Ghostty's `desktop-notifications`: off reads terminal notifications
    /// at once, as Ghostty then posts none (read per arrival, so a config
    /// reload applies).
    @ObservationIgnored var terminalNotificationsEnabled: @MainActor () -> Bool = {
        GhosttyRuntime.shared.desktopNotificationsEnabled
    }
    private static let logLimit = 64

    func start(services: AppServices) {
        self.services = services
        ProgramStatusSeenStore.shared.persist(to: .standard)
        desktopPostingEnabled = !services.environment.showcase
        feedBridge = Self.makeFeedBridge(services.feed)
        desktop.onOpen = { [weak self] _, surface in self?.open(surface: surface.map(SurfaceID.init(rawValue:))) }
        let store = services.daemon.store
        lastSeen = store.notifications.map(\.notification.rawValue).max() ?? 0
        tasks.append(Task { [weak self] in
            for await newest in Observations({ store.notifications.last?.notification.rawValue ?? 0 }) {
                guard let self, newest > self.lastSeen else { continue }
                let fresh = store.notifications.filter { $0.notification.rawValue > self.lastSeen }
                self.lastSeen = newest
                for notification in fresh { self.arrived(notification) }
            }
        })
        tasks.append(followViewedProgramStatus(store))
        tasks.append(Task { [weak self] in
            for await count in Observations({ [weak self] in self?.currentUnreadCount() ?? 0 }) {
                self?.updateDockBadge(count)
            }
        })
    }

    /// Follows `notifications.*` in every loaded snapshot.
    func follow(_ settings: SettingsController) {
        tasks.append(Task { [weak self] in
            for await prefs in Observations({ settings.snapshot.notifications }) {
                guard let self else { return }
                if self.preferences != prefs { self.preferences = prefs }
                self.updateDockBadge(self.currentUnreadCount())
            }
        })
    }

    /// The source of `tab`'s retained marker, from the daemon
    /// (`notification-source-v1`).
    func source(of tab: TabModel) -> NotificationSource {
        Self.source(tab.notification?.source)
    }

    /// The per-source settings a daemon source uses: `daemon` producers and
    /// daemons without sources count as agent, as before sources existed.
    nonisolated static func source(_ wire: String?) -> NotificationSource {
        wire.flatMap(NotificationSource.init(rawValue:)) ?? .agent
    }

    // MARK: Interactions

    /// A key reached `window`'s focused terminal or page (not an app shortcut).
    func noteTyping(in window: NSWindow?) {
        guard let tab = focusedTab(in: window) else { return }
        lastKeystroke[tab] = .now
        if isTerminalFocused(in: window) { clearUnreadMark(ofTab: tab) }
        interacted(.keystroke, tabID: tab)
    }

    /// A mouse-down landed in `window` (after AppKit dispatched it).
    func noteMouseDown(in window: NSWindow?) {
        guard let tab = focusedTab(in: window) else { return }
        interacted(.click, tabID: tab)
    }

    /// A window's focus settled: the viewed tab counts as focused while the
    /// window is key and cmux is active.
    func focusDidSettle(_ state: FocusState) {
        guard state.windowKey, state.appActive, let tab = Self.contentTab(state.resolved) else { return }
        interacted(.focus, tabID: tab)
    }

    /// Opens the tab of `surface` (banner click) and reads it per policy.
    func open(surface: SurfaceID?) {
        guard let services, let surface, let located = locate(surface: surface, in: services.daemon.store) else { return }
        let context = AppActionContext(services: services)
        context.reveal(located)
        interacted(.open, tabID: located.tab.id)
    }

    /// Opening from a verb (jump to unread): reads it unless the policy is `never`.
    func opened(_ tab: TabModel) {
        interacted(.open, tabID: tab.id)
    }

    func interacted(_ trigger: NotificationTrigger, tabID: String) {
        guard let services, let tab = Self.tab(id: tabID, in: services.daemon.store) else { return }
        // Any look at the tab sees its OSC 7501 done and error records
        // (client view state; the daemon keeps the records).
        ProgramStatusSeenStore.shared.markSeen(tab)
        guard tab.hasUnread else { return }
        guard NotificationPolicy.clears(trigger, mode: preferences.dismissal(for: source(of: tab))) else { return }
        note("\(trigger.rawValue) read \(tabID)")
        acknowledge(tab)
    }

    /// Typing into a terminal clears its workspace's manual unread mark, as
    /// terminal input did in the old app; focus, selection, and typing in
    /// a page or find bar keep it.
    private func clearUnreadMark(ofTab tab: String) {
        // Runs per keystroke: no tab walk unless some workspace is marked.
        guard let services, services.daemon.store.workspaces.contains(where: \.markedUnread),
              let workspace = WorkspaceUnreadMark.workspace(ofTab: tab, in: services.daemon.store),
              workspace.markedUnread else { return }
        // One clear per echo window, however fast the keys come.
        WorkspaceUnreadMark.set(false, on: [workspace], daemon: services.daemon, throttled: true)
    }

    /// Acknowledges `tab` in the daemon (a dismiss verb, or a policy trigger).
    func acknowledge(_ tab: TabModel) {
        timeouts.removeValue(forKey: tab.id)?.cancel()
        desktop.withdraw(banners.removeValue(forKey: tab.id) ?? [])
        feedBridge?.read(tab: tab.id)
        let surface = tab.surface
        services?.daemon.send("ack-tab-notifications") { _ = try await $0.acknowledgeNotifications(of: surface) }
    }

    // MARK: Arrival

    private func arrived(_ notification: DaemonNotification) {
        guard let services else { return }
        let store = services.daemon.store
        let source = Self.source(notification.source)
        let located = notification.surface.flatMap { locate(surface: $0, in: store) }
        if source == .terminal, !terminalNotificationsEnabled() {
            note("arrived \(notification.notification.rawValue) terminal off (desktop-notifications = false)")
            if let located { acknowledge(located.tab) }
            return
        }
        var arrival = NotificationPolicy.Arrival(source: source)
        arrival.appActive = NSApp.isActive
        if let located {
            arrival.workspaceMuted = preferences.mutedWorkspaces.contains(located.workspace.id)
            arrival.paneIsViewed = isViewed(located.tab.id)
            arrival.typedAgo = lastKeystroke[located.tab.id].map { Self.seconds(ContinuousClock.now - $0) }
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        arrival.minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let decision = NotificationPolicy.decide(arrival, prefs: preferences)
        note("arrived \(notification.notification.rawValue) \(source.rawValue) tab=\(located?.tab.id ?? "-") \(decision)")
        guard desktopPostingEnabled else {
            note("desktop posting suppressed")
            return
        }
        guard let located else {
            if decision.desktop { post(notification, tab: nil, workspace: nil, sound: decision.sound) }
            return
        }
        if decision.acknowledge {
            acknowledge(located.tab)
            return
        }
        // An OSC 7501 done for a terminal the user can see is read at once.
        let program = programStatus(of: notification, source: source, located: located)
        if let program, !program.notifies(visibility: visibility(of: located)) {
            note("program status \(program.reason.rawValue) visible: read at once")
            acknowledge(located.tab)
            return
        }
        // The feed (and the iPhone push) gets only what would alert on this Mac: muted
        // workspaces, quiet hours and banners turned off are not mirrored.
        if decision.desktop { mirrorToFeed(notification, source: source, located: located) }
        if decision.desktop {
            post(notification, tab: located.tab, workspace: located.workspace.id, sound: decision.sound,
                 subtitle: Self.bannerSubtitle(source: source, workspace: located.workspace.displayName), program: program)
        }
        if !decision.desktop, let sound = decision.sound { NotificationSounds.play(sound) }
        if let seconds = decision.timeout { scheduleTimeout(seconds, tabID: located.tab.id) }
    }

    private func post(_ notification: DaemonNotification, tab: TabModel?, workspace: String?, sound: String?,
                      subtitle: String? = nil, program: ProgramStatusNotification? = nil) {
        let id = "cmux-notification-\(notification.notification.rawValue)"
        let title = notification.title.isEmpty ? (tab?.displayTitle ?? "cmux") : notification.title
        desktop.post(id: id, title: title, subtitle: subtitle, body: notification.body, surface: notification.surface?.rawValue,
                     workspace: workspace, defaultSound: sound == "default",
                     attachment: program.flatMap { StatusNotificationImage.data($0.reason) })
        if let sound, sound != "default" { NotificationSounds.play(sound) }
        if let tab { banners[tab.id, default: []].append(id) }
    }

    /// A terminal program chose its banner's title and text (OSC 9/777/99,
    /// an OSC 7501 record), so the banner names the workspace it came from
    /// and a program cannot pose as one in another terminal. Other sources
    /// keep no subtitle.
    nonisolated static func bannerSubtitle(source: NotificationSource, workspace: String?) -> String? {
        guard source == .terminal, let workspace, !workspace.isEmpty else { return nil }
        return workspace
    }

    private func scheduleTimeout(_ seconds: Double, tabID: String) {
        let timer = timeouts[tabID] ?? DemandTimer(owner: "notifications.timeout", clock: clock)
        timeouts[tabID] = timer
        timer.schedule(after: .seconds(seconds)) { @MainActor [weak self] in
            self?.timeouts[tabID] = nil
            self?.interacted(.timeout, tabID: tabID)
        }
    }

    private func note(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }
}
