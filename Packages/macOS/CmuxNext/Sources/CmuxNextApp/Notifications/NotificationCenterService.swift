import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFloating
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextWakeups
import Observation
import CmuxNextFocus

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
    /// Highlights the user dismissed (Dismiss Highlight, cx-epgo): per
    /// workspace id, the newest notification id whose attention ring is
    /// hidden. A newer notification rings again. Presentation only: the
    /// notifications stay unread in the daemon.
    var dismissedHighlights: [String: UInt64] = [:]
    /// The daemon session the dismissed ids belong to: ids restart with a
    /// new session, so the dismissals apply only within this one.
    var dismissedHighlightSession: String?
    @ObservationIgnored weak var services: AppServices?
    /// Bumped when a window's settled focus changes: the viewed-tab rules
    /// (`followViewedProgramStatus`) re-read which tabs are viewed.
    private(set) var viewedRevision: UInt64 = 0
    /// The tabs viewed at the last viewed-tab pass: a tab marked unread
    /// (Mark Tab Unread) clears when it comes into view, not while it stays.
    @ObservationIgnored var viewedTabIDs: Set<String> = []
    @ObservationIgnored let desktop = DesktopNotifier()
    /// Pages' click handlers of their web notifications' banners.
    @ObservationIgnored let webNotificationClicks = WebNotificationClicks()
    @ObservationIgnored private var lastKeystroke: [String: ContinuousClock.Instant] = [:]
    /// `timeout` dismissal deadlines per tab id (one-shot `DemandTimer`s).
    @ObservationIgnored private var timeouts: [String: DemandTimer] = [:]
    /// OSC 7501 alerts held until their record arrives, by notification id
    /// (`NotificationCenterService+ProgramStatus`).
    @ObservationIgnored var heldProgramAlerts: [UInt64: Task<Void, Never>] = [:]
    /// Banner ids posted per tab id, withdrawn once the tab is read.
    @ObservationIgnored private var banners: [String: [String]] = [:]
    @ObservationIgnored let finishedBursts = FinishedBannerBursts()
    /// The Chief pet's notices (`NotificationCenterService+ChiefPet`); nil while it is off.
    @ObservationIgnored var chiefPet: ChiefPetController?
    @ObservationIgnored private var lastSeen: UInt64 = 0
    /// The Dock badge this service set last (nil: none).
    @ObservationIgnored var dockBadgeLabel: String?
    /// `notifications.dockBounce`: the running bounce, ended when nothing is unread.
    @ObservationIgnored let dockAttention = DockAttention()
    /// Hands the daemon's local feed items to the cloud owner (feed.md 9.1).
    @ObservationIgnored var feedDriver: FeedHandoffDriver?
    /// Agent permission prompts to the person's feed, while
    /// `feed.agentPermissionPrompts` is on (cx-aocz).
    @ObservationIgnored var permissionBridge: AcpmuxPermissionFeedBridge?
    /// Agent chat approval banners (cx-kz6m0.2) and this Mac's `install:<id>` they need.
    @ObservationIgnored let approvals = AgentApprovalBanners()
    @ObservationIgnored var localAgentHost: @MainActor () -> String? = { nil }
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// Recent arrivals and what was decided (for `debug.notifications`).
    @ObservationIgnored private(set) var log: [String] = []
    /// Showcase captures seed the real daemon ledger without showing banners
    /// or prompting for system authorization at launch.
    @ObservationIgnored var desktopPostingEnabled = true
    /// When a banner shows an agent's last message (Show Previews, like macOS) and the screen lock it reads; tests pin both.
    @ObservationIgnored var previews: NotificationPreviews = .whenUnlocked
    @ObservationIgnored var screenLocked: () -> Bool = { NotificationPreviews.screenIsLocked }
    /// The deadline clock; tests inject their own.
    @ObservationIgnored var clock: any Clock<Duration> = ContinuousClock()
    /// The languages banner titles the app writes are in (OSC 7501 alerts, cx-6so.36.8); tests pick one.
    @ObservationIgnored var localizations: [String] = Bundle.module.preferredLocalizations
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
        let feed = services.feed
        let principal = FeedInstallPrincipal(identity: services.cloud.installIdentity, baseURL: feed.apiBaseURL)
        let driver = makeFeedDriver(services, principal: principal)
        feedDriver = driver
        // The install id comes with the first install token: at launch and at each sign-in.
        tasks.append(Task { [weak feed] in
            for await signedIn in ObservationStream({ feed?.isSignedIn ?? false }) where signedIn { principal.refresh() }
        })
        // At activation (launch, sign-in, the first install token, a daemon
        // that starts serving the capability) one pass rebuilds the queue (B3).
        tasks.append(Task {
            // A trigger: an input change while active (a daemon restart, a new install id) rebuilds the queue again.
            for await active in ObservationStream({ ObservationTrigger(driver.isActive) }) where active.value { driver.run() }
        })
        tasks.append(followPermissionBridge(services, principal: principal))
        desktop.onOpen = { [weak self] id, surface in
            self?.open(surface: surface.map(SurfaceID.init(rawValue:)))
            self?.webNotificationClicks.run(bannerID: id)
        }
        desktop.onReply = { [weak self] id, surface, text in
            self?.reply(banner: id, surface: surface.map(SurfaceID.init(rawValue:)), text: text)
        }
        followApprovals(services)
        let store = services.daemon.store
        lastSeen = store.notifications.map(\.notification.rawValue).max() ?? 0
        tasks.append(Task { [weak self] in
            for await newest in ObservationStream({ store.notifications.last?.notification.rawValue ?? 0 }) {
                guard let self, newest > self.lastSeen else { continue }
                let fresh = store.notifications.filter { $0.notification.rawValue > self.lastSeen }
                self.lastSeen = newest
                for notification in fresh { self.arrived(notification) }
            }
        })
        tasks.append(followViewedProgramStatus(store))
        tasks.append(followNotificationLedger(services.daemon))
        tasks.append(Task { [weak self] in
            for await count in ObservationStream({ [weak self] in self?.currentUnreadCount() ?? 0 }) {
                self?.updateDockBadge(count)
                self?.dropReadChiefPetNotices()
            }
        })
    }

    /// Follows `notifications.*` in every loaded snapshot.
    func follow(_ settings: SettingsController) {
        tasks.append(Task { [weak self] in
            for await prefs in ObservationStream({ settings.snapshot.notifications }) {
                guard let self else { return }
                if self.preferences != prefs { self.preferences = prefs }
                self.updateDockBadge(self.currentUnreadCount())
            }
        })
        followChiefPet(settings)
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

    /// A window's settled focus changed (window key, app active, workspace or
    /// keyboard target): the viewed tab counts as focused while the window is
    /// key and cmux is active. The viewed-tab rules read it (one path for a
    /// focus and for an unread mark that lands on a viewed tab).
    func focusDidSettle(_ state: FocusState, in controller: WindowController) {
        viewedRevision &+= 1
    }

    /// Opens the tab of `surface` (banner click) and reads it per policy.
    func open(surface: SurfaceID?) {
        guard let services, let surface, let located = locate(surface: surface, in: services.daemon.store) else { return }
        let context = AppActionContext(services: services)
        context.reveal(located)
        interacted(.open, tabID: located.tab.id)
    }

    /// A reply banner's text (`notify --reply`) for the terminal of `surface`:
    /// pasted, then Return as its own key, as the old app sent it (a full-screen
    /// agent editor reads a pasted newline as a line break, not a submit). The
    /// reply answered the notification, so its tab is read.
    /// Only while the banner's notification is still the tab's unread one: a
    /// banner left in Notification Center from an earlier launch, or one a newer
    /// notification replaced, must not type into whatever runs there now.
    func reply(banner: String, surface: SurfaceID?, text: String) {
        guard let services, let surface, !text.isEmpty, let located = locate(surface: surface, in: services.daemon.store),
              located.tab.kind == .pty, let marker = located.tab.notification, marker.unread,
              banner == "cmux-notification-\(marker.notification.rawValue)" else {
            note("reply refused: \(banner) is not the tab's unread notification")
            return
        }
        type(text, into: located)
    }

    /// Opening from a verb (jump to unread): reads it unless the policy is `never`.
    func opened(_ tab: TabModel) {
        interacted(.open, tabID: tab.id)
    }

    func interacted(_ trigger: NotificationTrigger, tabID: String) {
        guard let services, let tab = Self.tab(id: tabID, in: services.daemon.store) else { return }
        interacted(trigger, tab: tab)
    }

    func interacted(_ trigger: NotificationTrigger, tab: TabModel) {
        // Any look at the tab sees its OSC 7501 done and error records and an
        // agent chat's completed turn (client view state; the owners keep the facts).
        ProgramStatusSeenStore.shared.markSeen(tab)
        guard tab.hasUnread else { return }
        guard NotificationPolicy(prefs: preferences).clears(trigger, for: source(of: tab)) else { return }
        note("\(trigger.rawValue) read \(tab.id)")
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
        note("ack \(tab.id)")
        timeouts.removeValue(forKey: tab.id)?.cancel()
        approvals.forget(tab: tab.id, retire: true)
        finishedBursts.read(tab: tab.id)
        chiefPet?.read(tab: tab.id)
        desktop.withdraw(banners.removeValue(forKey: tab.id) ?? [])
        let surface = tab.surface
        let driver = feedDriver
        services?.daemon.send("ack-tab-notifications") { connection in
            let reply = try await connection.acknowledgeNotifications(of: surface)
            // Items that already moved are read in the cloud (B5).
            if let refused = reply.refused, !refused.isEmpty { await driver?.acknowledged(refused) }
        }
    }

    // MARK: Arrival

    private func arrived(_ notification: DaemonNotification) {
        guard let services else { return }
        let store = services.daemon.store
        arrive(notification, located: notification.surface.flatMap { locate(surface: $0, in: store) })
    }

    /// One arrival on `located` (nil: its tab is not in the store). `visibility` is where the tab
    /// is for the user now (`visibility(of:)` when nil); tests pass their own.
    func arrive(_ notification: DaemonNotification, located: LocatedTab?, visibility: TerminalVisibility? = nil) {
        let source = Self.source(notification.source)
        if source == .terminal, !terminalNotificationsEnabled() {
            note("arrived \(notification.notification.rawValue) terminal off (desktop-notifications = false)")
            if let located { acknowledge(located.tab) }
            return
        }
        var arrival = NotificationPolicy.Arrival(source: source)
        arrival.bannerAllowed = notification.desktop
        arrival.appActive = NSApp.isActive
        if let located {
            arrival.workspaceMuted = preferences.mutedWorkspaces.contains(located.workspace.id)
            arrival.paneIsViewed = isViewed(located.tab.id)
            arrival.typedAgo = lastKeystroke[located.tab.id].map { Self.seconds(ContinuousClock.now - $0) }
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        arrival.minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let decision = NotificationPolicy(prefs: preferences).decide(arrival)
        note("arrived \(notification.notification.rawValue) \(source.rawValue) tab=\(located?.tab.id ?? "-") \(decision)")
        guard let located else {
            guard desktopPostingEnabled else { return note("desktop posting suppressed") }
            feedDriver?.run()
            if decision.desktop { post(notification, tab: nil, workspace: nil, sound: decision.sound) }
            if !notification.desktop, let sound = decision.sound { NotificationSounds.playWithoutBanner(sound) }
            if let mode = decision.bounce { dockAttention.bounce(untilActive: mode == .untilActive) }
            return
        }
        if decision.acknowledge {
            acknowledge(located.tab)
            return
        }
        // A turn that finished in front of the user is already seen (default call, cx-slk1h): the
        // history keeps it, read. An agent that asks or fails stays unread even there, and so does
        // an earlier ask or error the tab still holds (acknowledging reads the whole tab).
        let shown = visibility ?? self.visibility(of: located)
        if notification.isFinishedTurn, shown.isVisible, !located.tab.holdsUnreadAsk(besides: notification) {
            note("finished turn visible: read at once")
            acknowledge(located.tab)
            return
        }
        let program = programStatus(of: notification, source: source, located: located)
        if program == nil, source == .terminal,
           ProgramStatusNotification.looksLikeAlert(title: notification.title, level: notification.level) {
            holdUntilRecord(notification, located: located) { [weak self] found in
                self?.deliver(notification, source: source, located: located, decision: decision, program: found)
            }
            return
        }
        deliver(notification, source: source, located: located, decision: decision, program: program, visibility: shown)
    }

    /// The rest of an arrival once its OSC 7501 record (if any) is known.
    func deliver(_ notification: DaemonNotification, source: NotificationSource, located: LocatedTab,
                 decision: NotificationPolicy.Decision, program: ProgramStatusNotification?,
                 visibility: TerminalVisibility? = nil) {
        // An OSC 7501 done for a terminal the user can see is read at once.
        if let program, !program.notifies(visibility: visibility ?? self.visibility(of: located)) {
            note("program status \(program.reason.rawValue) visible: read at once")
            acknowledge(located.tab)
            return
        }
        // The feed (and the iPhone push) gets only what would alert on this Mac: the
        // driver's pass applies the policy to the daemon's item, and a notice that did
        // not alert here (pane in view, app active, banners off) stays local.
        moveToTop(located.workspace)
        notifyChiefPet(notification, located: located, decision: decision, program: program)
        // Showcase captures read and order rows as the app does, and post nothing.
        guard desktopPostingEnabled else {
            note("desktop posting suppressed")
            if let seconds = decision.timeout { scheduleTimeout(seconds, tabID: located.tab.id) }
            return
        }
        feedDriver?.noteArrival(terminal: located.tab.terminalResourceID?.rawValue, alerted: decision.alerts)
        feedDriver?.run()
        if decision.desktop {
            // Agents finishing together in one workspace share one silent digest banner (FinishedBannerBursts).
            let digest = program == nil ? finishedBursts.join(notification, workspace: located.workspace.id, tab: located.tab.id, clock: clock) : nil
            desktop.withdraw(digest?.replacing ?? [])
            post(notification, tab: located.tab, workspace: located.workspace.id, sound: digest == nil ? decision.sound : nil,
                 subtitle: digest == nil ? notification.shownSubtitle ?? Self.bannerSubtitle(source: source, workspace: located.workspace.displayName) : located.workspace.displayName,
                 program: program, title: digest.map { String(localized: "notifications.finishedBurst.title", defaultValue: "\($0.count) agents finished",
                                                                    table: "NotificationsPanel", bundle: .module) })
        }
        if !decision.desktop, let sound = decision.sound {
            notification.desktop ? NotificationSounds.play(sound) : NotificationSounds.playWithoutBanner(sound)
        }
        if let seconds = decision.timeout { scheduleTimeout(seconds, tabID: located.tab.id) }
        if let mode = decision.bounce { dockAttention.bounce(untilActive: mode == .untilActive) }
    }

    private func post(_ notification: DaemonNotification, tab: TabModel?, workspace: String?, sound: String?,
                      subtitle: String? = nil, program: ProgramStatusNotification? = nil, title: String? = nil) {
        let id = "cmux-notification-\(notification.notification.rawValue)"
        // An OSC 7501 alert reads in the app's language; the daemon's English is the fallback.
        let title = title ?? program?.title(localizations: localizations)
            ?? (notification.title.isEmpty ? (tab?.displayTitle ?? "cmux") : notification.title)
        // An agent chat's permission prompt: Allow once and Deny, and what it asks as the body.
        withApproval(of: notification, tab: tab) { [weak self] approval in
            guard let self else { return }
            self.desktop.post(id: id, title: title, subtitle: subtitle, body: approval?.summary ?? notification.bannerBody(previews: self.previews, screenLocked: self.screenLocked()),
                              surface: notification.surface?.rawValue, workspace: workspace, defaultSound: sound == "default",
                              attachment: program.flatMap { StatusNotificationImage.data($0.reason) },
                              reply: notification.reply && tab?.kind == .pty, approval: approval != nil)
            if let sound, sound != "default" { NotificationSounds.play(sound) }
            if let tab {
                self.banners[tab.id, default: []].append(id)
                self.approvals.keep(id, approval: approval, tab: tab.id)
            }
        }
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

    func note(_ line: String) {
        log.append(line)
        if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
    }
}
