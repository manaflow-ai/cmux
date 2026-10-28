import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFloating
import CmuxNextMobileHost
import CmuxNextSettings
import CmuxNextTerminal
import CmuxNextWakeups
import Observation
import CmuxNextFocus
import CmuxNextFeed

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
    /// Marked-unread rings the user dismissed: per tab id, the
    /// ``TabModel/markedUnreadGeneration`` hidden. Marking the tab again rings again.
    var dismissedMarks: [String: UInt64] = [:]
    @ObservationIgnored weak var services: AppServices?
    /// Bumped when a window's settled focus changes: the viewed-tab rules
    /// (`followViewedProgramStatus`) re-read which tabs are viewed.
    private(set) var viewedRevision: UInt64 = 0
    /// The tabs viewed at the last viewed-tab pass: a tab marked unread
    /// (Mark Tab Unread) clears when it comes into view, not while it stays.
    @ObservationIgnored var viewedTabIDs: Set<String> = []
    /// Tabs read because the person went into their pane (a click, a key, an
    /// open), until the layout takes them for the ring's dismiss flash.
    @ObservationIgnored var entryReads: Set<String> = []
    /// A press on a pane's tab strip, read on its mouse-up unless it dragged
    /// (`NotificationCenterService+StripPress`).
    @ObservationIgnored var stripPress: StripPress?
    /// Tabs a strip press picked up, whose focus is not a look until the person's next input
    /// (`NotificationCenterService+StripPress`).
    @ObservationIgnored var viewHolds: Set<String> = []
    /// Whether the left button is still down, and where the pointer is (screen coordinates);
    /// tests stand in for the hardware.
    @ObservationIgnored var leftButtonIsDown: @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }
    @ObservationIgnored var pointerLocation: @MainActor () -> NSPoint = { NSEvent.mouseLocation }
    /// Agent chat tabs whose turn ended, by the generation of their ring: the pane rings until
    /// the person goes into it (acpmux reads a turn that ends in a shown chat at once, so no
    /// notification marks it). Observed: the attention marks follow it.
    var agentFinished: [String: UInt64] = [:]
    /// Ring generations for ``agentFinished``, above any notification id, so a new finish
    /// restarts the ring's arrival and never equals a notification's mark.
    @ObservationIgnored private var agentFinishGeneration: UInt64 = 1 << 62
    /// When an agent chat's ring last pulsed, for coalescing a burst of turn ends.
    @ObservationIgnored private var lastAgentPulse: ContinuousClock.Instant?
    /// Agent chats whose ring arrives at rest, with no pulse: a later finish in a burst.
    @ObservationIgnored var quietAgentFinishes: Set<String> = []
    @ObservationIgnored let desktop = DesktopNotifier()
    /// A passkey request's banner was clicked (its request id): the passkey hand-off answers it
    /// (plans/cmux-next/agent-browser-passkey-DESIGN.md 3.2).
    @ObservationIgnored var onPasskeyBanner: ((String) -> Void)?
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
    /// Every sound cmux plays passes here (burst cooldown, player; `notifications.sounds`); tests pass a recorder.
    @ObservationIgnored var soundGate = NotificationSoundGate()
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
    /// Workspace statuses `followStatusRuns` examined since start: what a status change costs it
    /// (tests read it; it must follow the workspaces whose status changed, not the session).
    @ObservationIgnored var statusRunVisits = 0
    /// Recent arrivals and what was decided (for `debug.notifications`).
    @ObservationIgnored private(set) var log: [String] = []
    /// Showcase captures seed the real daemon ledger without showing banners
    /// or prompting for system authorization at launch.
    @ObservationIgnored var desktopPostingEnabled = true
    /// When a banner shows an agent's last message (`notifications.showPreviews`, like macOS's
    /// Show Previews), and the screen lock it reads; tests pin both.
    var previews: NotificationPreviews {
        get { preferences.showPreviews }
        set { preferences.showPreviews = newValue }
    }
    /// What each banner says: where, who and state, what (`NotificationBannerFormatter`).
    @ObservationIgnored var bannerFormatter = NotificationBannerFormatter()
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
        AgentTurnStateStore.shared.onTurnEnded = { [weak self] session in self?.agentTurnEnded(session: session) }
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
            if id == IPhonePairNotices.id { try? self?.services?.settingsWindow.show(section: nil, route: IPhonePairNotices.settingsRoute); return }
            if let request = AppBrowserPasskeyHost.requestID(banner: id) { self?.onPasskeyBanner?(request); return }
            if self?.services?.agentTabs.pageChats.runNotices?.open(banner: id) == true { return }
            self?.open(surface: surface.map(SurfaceID.init(rawValue:)))
            self?.webNotificationClicks.run(bannerID: id)
        }
        desktop.onReply = { [weak self] id, surface, text in
            self?.reply(banner: id, surface: surface.map(SurfaceID.init(rawValue:)), text: text)
        }
        desktop.onMarkRead = { [weak self] id, surface in
            guard let self, let store = self.services?.daemon.store else { return }
            self.markRead(banner: id, surface: surface.map(SurfaceID.init(rawValue:)), in: store)
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
        tasks.append(followStatusRuns(store))
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
        NotificationSource(wire: tab.notification?.source)
    }

    // MARK: Interactions

    /// A key reached `window`'s focused terminal or page (not an app shortcut).
    func noteTyping(in window: NSWindow?) {
        guard let tab = focusedTab(in: window) else { return }
        lastKeystroke[tab] = .now
        if isTerminalFocused(in: window) { clearUnreadMark(ofTab: tab) }
        interacted(.keystroke, tabID: tab)
    }

    /// A mouse-down landed in `window` at `location` (window coordinates,
    /// after AppKit dispatched it): reads the pane under the pointer, never
    /// another one, so a ring stays until its own pane is clicked. A click
    /// outside the panes (sidebar, titlebar, tab bar gaps) reads nothing. A
    /// left press on a pane's tab strip waits for its mouse-up (``noteMouseUp(in:at:)``):
    /// it may start dragging the tab or the pane, and the ring goes with it.
    /// `screen`: where it went down before dispatch (a titlebar press may have moved the window
    /// since); `synthetic`: the app's own input (`SyntheticInput`), whose button is no hardware's.
    func noteMouseDown(in window: NSWindow?, at location: NSPoint, left: Bool = true,
                       screen: NSPoint? = nil, synthetic: Bool = false) {
        // A right or middle press during a strip drag leaves the drag alone.
        if !left, stripPress != nil, leftButtonIsDown() { return }
        // Any new press ends the holds of earlier moves: the person has moved on.
        stripPress = nil
        endViewHolds()
        guard let press = clickedTab(in: window, at: location) else { return }
        if left, press.onStrip, let window {
            beginStripPress(tab: press.tab, at: screen ?? window.convertPoint(toScreen: location), synthetic: synthetic)
            return
        }
        interacted(.click, tabID: press.tab)
    }

    /// The selected tab of the pane under `location` in `window`. A child
    /// window (a Chromium page's) is hit-tested in the workspace window it
    /// belongs to. A window outside any workspace window, or one showing a top
    /// page, reads the tab that has the keyboard, which the click gave it.
    /// `onStrip`: the press is on the pane's tab strip, found from the pane's own
    /// strip rather than a window hit test (in the top row the titlebar takes that).
    func clickedTab(in window: NSWindow?, at location: NSPoint) -> (tab: String, onStrip: Bool)? {
        guard let services, let window else { return nil }
        let host = CmuxApplication.accessibilityWindow(for: window) ?? window
        guard let controller = services.windows.controllers.first(where: { $0.window === host }),
              controller.state.page == nil, let content = controller.content else { return focusedTab(in: window).map { ($0, false) } }
        let inHost = host === window ? location : host.convertPoint(fromScreen: window.convertPoint(toScreen: location))
        let root = content.layoutView
        let point = root.convert(inHost, from: nil)
        let hits = content.layoutModel.visiblePanes.filter { root.frame(of: $0)?.contains(point) == true }
        // Overlapping panes (a docked column over the strip): the click focused the front one. A
        // click there that moved no focus reads nothing rather than a guess.
        let focused = controller.focus.state.pane
        guard let pane = hits.first(where: { $0.rawValue == focused }) ?? (hits.count == 1 ? hits.first : nil),
              let model = content.paneModel(key: pane.rawValue), !model.tabs.isEmpty else { return nil }
        let selected = controller.state.selection.selection(in: model.id)
        let tab = (model.tabs.first { $0.id == selected } ?? model.tabs[min(max(model.defaultTabIndex, 0), model.tabs.count - 1)]).id
        let strip = content.panes[pane]?.view.stripView
        let onStrip = strip.map { $0.window === host && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.contains($0.convert(inHost, from: nil)) } ?? false
        return (tab, onStrip)
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

    /// A banner's Mark as Read: reads the tab of `surface` in place (no window, no focus change),
    /// as a dismiss verb does.
    func markRead(banner: String, surface: SurfaceID?, in store: DaemonStore) {
        guard let surface, let located = locate(surface: surface, in: store) else {
            note("mark read: \(banner) has no tab")
            return
        }
        note("mark read \(banner) \(located.tab.id)")
        ProgramStatusSeenStore.shared.markSeen(located.tab)
        acknowledge(located.tab)
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
        // Going into a tab a strip press held ends the hold: its focus is a look again.
        if [.click, .keystroke, .open].contains(trigger), !viewHolds.isEmpty { viewHolds.remove(tab.id) }
        // Any look at the tab sees its OSC 7501 done and error records and an
        // agent chat's completed turn (client view state; the owners keep the facts).
        ProgramStatusSeenStore.shared.markSeen(tab)
        if agentFinished[tab.id] != nil, NotificationPolicy(prefs: preferences).clears(trigger, for: .agent) {
            note("\(trigger.rawValue) read agent turn \(tab.id)")
            agentFinished[tab.id] = nil
            quietAgentFinishes.remove(tab.id)
            if DesignSettings.shared.attention.flashesOnEntry(trigger) { entryReads.insert(tab.id) }
        }
        readMark(trigger, tab: tab)
        guard tab.hasUnread else { return }
        guard NotificationPolicy(prefs: preferences).clears(trigger, for: source(of: tab)) else { return }
        note("\(trigger.rawValue) read \(tab.id)")
        if DesignSettings.shared.attention.flashesOnEntry(trigger) { entryReads.insert(tab.id) }
        acknowledge(tab)
    }

    /// Going into a pane (a click or a key) reads its tab's Mark as Unread, as it reads an unread
    /// notification: the ring both draw goes with it. Focus alone keeps the mark (a tab marked
    /// while viewed stays marked until it is viewed again, ``clearTabMarks(entering:)``).
    private func readMark(_ trigger: NotificationTrigger, tab: TabModel) {
        guard tab.markedUnread, trigger == .click || trigger == .keystroke, let services else { return }
        note("\(trigger.rawValue) read mark \(tab.id)")
        if DesignSettings.shared.attention.flashesOnEntry(trigger) { entryReads.insert(tab.id) }
        try? TabUnreadMark.set(false, tab: tab, daemon: services.daemon)
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
        if agentFinished[tab.id] != nil { agentFinished[tab.id] = nil }
        quietAgentFinishes.remove(tab.id)
        timeouts.removeValue(forKey: tab.id)?.cancel()
        approvals.forget(tab: tab.id, retire: true)
        finishedBursts.read(tab: tab.id)
        chiefPet?.read(tab: tab.id)
        desktop.withdraw(banners.removeValue(forKey: tab.id) ?? [])
        let surface = tab.surface
        let driver = feedDriver
        // Read now (dots, badges, Cmd-Opt-U); the tree's echo settles it, a failed ack rolls it back.
        tab.expectNotificationRead()
        services?.daemon.send("ack-tab-notifications", onFailure: { _ in tab.dropExpectedNotificationRead() }) { connection in
            let reply = try await connection.acknowledgeNotifications(of: surface)
            // Items that already moved are read in the cloud (B5).
            if let refused = reply.refused, !refused.isEmpty { await driver?.acknowledged(refused) }
        }
    }

    /// An agent chat's turn ended: with `notifications.attention.agentChats` on (off by default),
    /// ring the panes that show its tab until the person goes in. Off, nothing rings: acpmux reads
    /// a turn that ends in a shown chat at once, as before #22678. A chat the person is looking at
    /// (the focused content of the key window) never rings, and a burst pulses once: a finish
    /// within `burstWindow` of the last pulse rings at rest (cmuxterm-hq#2959).
    func agentTurnEnded(session: String) {
        guard let services else { return }
        agentTurnEnded(session: session, in: services.daemon.store.workspaces)
    }

    func agentTurnEnded(session: String, in workspaces: [WorkspaceModel],
                        rings: Bool = DesignSettings.shared.attention.rings(agentChat: true),
                        viewed: ((String) -> Bool)? = nil, now: ContinuousClock.Instant = .now) {
        guard rings else { return }
        for workspace in workspaces {
            for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs)
            where tab.agentSession?.session == session && !(viewed?(tab.id) ?? isViewed(tab.id)) {
                agentFinishGeneration &+= 1
                agentFinished[tab.id] = agentFinishGeneration
                if let last = lastAgentPulse, now - last < Self.burstWindow {
                    quietAgentFinishes.insert(tab.id)
                } else {
                    quietAgentFinishes.remove(tab.id)
                    lastAgentPulse = now
                }
                note("agent turn ended \(tab.id)")
            }
        }
    }

    /// Turn ends closer together than this pulse once; the rest ring at rest.
    static let burstWindow: Duration = .milliseconds(900)

    // MARK: Arrival

    private func arrived(_ notification: DaemonNotification) {
        guard let services else { return }
        let store = services.daemon.store
        let located = notification.surface.flatMap { locate(surface: $0, in: store) }
        arrive(notification, located: located, workspace: located == nil ? Self.workspace(of: notification, in: store) : nil)
    }

    /// The workspace a terminal-less notification names (`cmux notify --workspace ws_…`), when
    /// it is in `store`.
    static func workspace(of notification: DaemonNotification, in store: DaemonStore) -> WorkspaceModel? {
        guard notification.surface == nil, let id = notification.workspaceID else { return nil }
        return store.workspace(resourceID: id)
    }

    /// One arrival on `located` (nil: its tab is not in the store). `workspace`: the workspace a
    /// notification with no tab belongs to (`notify --workspace`), else nil. `visibility` is where
    /// the tab is for the user now (`visibility(of:)` when nil); tests pass their own.
    func arrive(_ notification: DaemonNotification, located: LocatedTab?, workspace: WorkspaceModel? = nil,
                visibility: TerminalVisibility? = nil) {
        let source = NotificationSource(wire: notification.source)
        if source == .terminal, !terminalNotificationsEnabled() {
            note("arrived \(notification.notification.rawValue) terminal off (desktop-notifications = false)")
            if let located { acknowledge(located.tab) }
            return
        }
        var arrival = NotificationPolicy.Arrival(source: source)
        arrival.bannerAllowed = notification.desktop
        arrival.appActive = NSApp.isActive
        if let workspace = located?.workspace ?? workspace {
            arrival.workspaceMuted = preferences.mutedWorkspaces.contains(workspace.id)
        }
        (arrival.soundEvent, arrival.soundScope) = soundGate.classify(level: notification.level.rawValue, source: source,
                                                                     agent: located?.tab.agentSession?.harness ?? located?.tab.agent?.agent, workspace: (located?.workspace ?? workspace)?.id)
        if let located {
            arrival.paneIsViewed = isViewed(located.tab.id)
            arrival.typedAgo = lastKeystroke[located.tab.id].map { Self.seconds(ContinuousClock.now - $0) }
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        arrival.minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        var decision = NotificationPolicy(prefs: preferences).decide(arrival)
        note("arrived \(notification.notification.rawValue) \(source.rawValue) tab=\(located?.tab.id ?? "-") \(decision)")
        guard let located else {
            guard desktopPostingEnabled else { return note("desktop posting suppressed") }
            feedDriver?.run()
            if let workspace, decision.attention { moveToTop(workspace) }
            soundGate.admit(&decision, cooldownSeconds: preferences.sounds.cooldownSeconds)
            if decision.desktop {
                // A workspace's notification names its workspace in the title, as a terminal's does.
                post(notification, tab: nil, workspace: workspace?.id, workspaceName: workspace?.displayName,
                     sound: decision.sound, volume: decision.soundVolume)
            }
            if !notification.desktop, let sound = decision.sound { soundGate.player.play(sound, volume: decision.soundVolume, banner: false) }
            if let mode = decision.bounce { dockAttention.bounce(untilActive: mode == .untilActive) }
            return
        }
        if decision.acknowledge {
            // Read on sight: under `sounds.when = always` it still sounds (no banner shows for it).
            soundGate.playSeen(decision, sounds: preferences.sounds)
            acknowledge(located.tab)
            return
        }
        // A turn that finished in front of the user is already seen (cx-slk1h) when the dismissal
        // reads a pane on sight (`focus`, the default): the history keeps it, read. Under `click`
        // its ring stays until the pane is clicked or typed in. An agent that asks or
        // fails stays unread even there, and so does an earlier ask or error the tab still holds
        // (acknowledging reads the whole tab).
        let shown = visibility ?? self.visibility(of: located)
        if notification.isFinishedTurn, shown.isVisible, !located.tab.holdsUnreadAsk(besides: notification) {
            guard NotificationPolicy(prefs: preferences).clears(.focus, for: source) else {
                // Seen finishing, so no banner; the ring waits for a click in the pane.
                return keepSeenUnread(located, decision: decision, note: "finished turn visible: kept unread, no banner")
            }
            note("finished turn visible: read at once")
            soundGate.playSeen(decision, sounds: preferences.sounds)
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

    /// An arrival the user saw land, kept unread for a click in its pane: it posts nothing, the
    /// feed hears it did not alert here (so it is not mirrored to the iPhone), and the timeout
    /// dismissal still gets its deadline.
    private func keepSeenUnread(_ located: LocatedTab, decision: NotificationPolicy.Decision, note line: String) {
        note(line)
        soundGate.playSeen(decision, sounds: preferences.sounds)
        feedDriver?.noteArrival(terminal: located.tab.terminalResourceID?.rawValue, alerted: false)
        if let seconds = decision.timeout { scheduleTimeout(seconds, tabID: located.tab.id) }
    }

    /// The rest of an arrival once its OSC 7501 record (if any) is known.
    func deliver(_ notification: DaemonNotification, source: NotificationSource, located: LocatedTab,
                 decision held: NotificationPolicy.Decision, program: ProgramStatusNotification?,
                 visibility: TerminalVisibility? = nil) {
        var decision = held
        // An OSC 7501 done for a terminal the user can see posts nothing (cx-kxa2). It is read at
        // once when the dismissal reads a pane on sight (`focus`); under `click` its ring stays
        // until the pane is clicked or typed in.
        if let program, !program.notifies(visibility: visibility ?? self.visibility(of: located)) {
            guard NotificationPolicy(prefs: preferences).clears(.focus, for: source) else {
                return keepSeenUnread(located, decision: decision, note: "program status \(program.reason.rawValue) visible: kept unread, no banner")
            }
            note("program status \(program.reason.rawValue) visible: read at once")
            soundGate.playSeen(decision, sounds: preferences.sounds)
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
        soundGate.admit(&decision, cooldownSeconds: preferences.sounds.cooldownSeconds)
        if decision.desktop {
            // Agents finishing together in one workspace share one silent digest banner (FinishedBannerBursts).
            let digest = program == nil ? finishedBursts.join(notification, workspace: located.workspace.id, tab: located.tab.id, clock: clock) : nil
            desktop.withdraw(digest?.replacing ?? [])
            // A digest names only its workspace: its agents sit in several tabs.
            post(notification, tab: digest == nil ? located.tab : nil, workspace: located.workspace.id,
                 workspaceName: located.workspace.displayName, sound: digest == nil ? decision.sound : nil, volume: decision.soundVolume,
                 program: program, headline: digest.map { String(localized: "notifications.finishedBurst.title", defaultValue: "\($0.count) agents finished",
                                                                       table: "NotificationsPanel", bundle: .module) },
                 owner: located.tab)
        }
        if !decision.desktop, let sound = decision.sound { soundGate.player.play(sound, volume: decision.soundVolume, banner: notification.desktop) }
        if let seconds = decision.timeout { scheduleTimeout(seconds, tabID: located.tab.id) }
        if let mode = decision.bounce { dockAttention.bounce(untilActive: mode == .untilActive) }
    }

    /// Posts `notification`'s banner. `tab` is the tab the banner names (nil: a digest, or no
    /// tab in the store); `owner` (default `tab`) is the tab whose read withdraws it. The title is
    /// where it came from (`workspaceName › tab`), which the app writes, so a terminal program
    /// cannot pose as another terminal; the poster's title is the subtitle.
    private func post(_ notification: DaemonNotification, tab: TabModel?, workspace: String?, workspaceName: String? = nil,
                      sound: String?, volume: Double = 1, program: ProgramStatusNotification? = nil, headline: String? = nil,
                      owner: TabModel? = nil) {
        let id = "cmux-notification-\(notification.notification.rawValue)"
        let owner = owner ?? tab
        // An OSC 7501 alert reads in the app's language; the daemon's English is the fallback.
        let headline = headline ?? program?.title(localizations: localizations) ?? notification.title
        // An agent chat's permission prompt: Allow once and Deny, and what it asks as the body.
        withApproval(of: notification, tab: owner) { [weak self] approval in
            guard let self else { return }
            let content = self.bannerFormatter.content(
                headline: headline, posterSubtitle: notification.shownSubtitle,
                body: approval?.summary ?? notification.bannerBody(previews: self.previews, screenLocked: self.screenLocked()),
                workspace: workspaceName, tab: tab.map { self.shownName(of: $0) }, host: tab?.remote?.sessionName, plain: approval == nil)
            self.desktop.post(id: id, title: content.title, subtitle: content.subtitle, body: content.body,
                              surface: notification.surface?.rawValue, workspace: workspace, defaultSound: sound == "default",
                              attachment: program.flatMap { StatusNotificationImage.data($0.reason) },
                              reply: notification.reply && owner?.kind == .pty, approval: approval != nil)
            if let sound, sound != "default" { self.soundGate.player.play(sound, volume: volume, banner: true) }
            if let owner {
                self.banners[owner.id, default: []].append(id)
                self.approvals.keep(id, approval: approval, tab: owner.id)
            }
        }
    }

    /// The name a banner or the Chief pet gives `tab`: a Home conversation tab its conversation's
    /// (a Chief's own name, as its tab strip shows it), any other tab its record's.
    func shownName(of tab: TabModel) -> String {
        guard tab.kind == .conversation, let home = services?.home else { return tab.displayTitle }
        return home.tabTitle(for: tab)
    }

    private func scheduleTimeout(_ seconds: Double, tabID: String) {
        note("timeout \(tabID) in \(seconds)s")
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
