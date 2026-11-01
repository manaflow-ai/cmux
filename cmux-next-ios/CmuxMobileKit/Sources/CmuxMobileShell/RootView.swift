#if os(iOS)
import CmuxMobileAgentChat
import CmuxMobileAuth
import CmuxMobileArtifacts
import CmuxMobileBrowserStream
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileFeed
import CmuxMobileLive
import CmuxMobileModel
import CmuxMobileNotifications
import CmuxMobileTransport
import CmuxMobileOnboarding
import CmuxMobileScreenSharing
import CmuxMobileSettings
import CmuxMobileVoice
import CmuxMobileSupport
import SwiftUI
import OSLog
import UIKit

private let log = Logger(subsystem: "dev.cmux.mobile", category: "shell")
private let theme = CmuxMobileTheme.standard

/// Launch options read from the process (DEBUG verification hooks included).
public struct ShellLaunchOptions: Sendable {
    public var initialTab: String?
    public var sidebarOpen = false
    public var demo: String?
    public var forceSetup = false
    public var initialEmail: String?
    /// DEBUG: open setup on the Connect your Mac step, with no Mac until a
    /// few seconds in (the presence flip, for recordings).
    public var setupPairDemo = false
    /// DEBUG: open Settings on this page (`SettingsRoute` case name).
    public var settingsPage: String?
    /// A launch with no demo or forced page goes back to the workspace and
    /// tab that were open (design/terminal P10). `-cmux-mobile-no-restore` opts out.
    public var restoresLastLocation = true

    public init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        #if DEBUG
        initialTab = value("-cmux-mobile-tab")
        sidebarOpen = arguments.contains("-cmux-mobile-sidebar-open")
        demo = value("-cmux-mobile-demo") ?? DeveloperOptions.launchDemo.flatMap { DemoDriver.names.contains($0) ? $0 : nil }
        forceSetup = arguments.contains("-cmux-mobile-setup")
        initialEmail = value("-cmux-mobile-email")
        setupPairDemo = arguments.contains("-cmux-mobile-setup-pair")
        if setupPairDemo { forceSetup = true }
        settingsPage = value("-cmux-mobile-settings-page")
        restoresLastLocation = initialTab == nil && settingsPage == nil && demo == nil && !sidebarOpen
            && !arguments.contains("-CmuxMobileDemo") && DeveloperOptions.launchDemo == nil
        #endif
        if arguments.contains("-cmux-mobile-no-restore") { restoresLastLocation = false }
    }
}

/// The app's root: launch handoff, then Welcome (signed out), first-run setup,
/// or the shell (signed in).
public struct RootView: View {
    @State private var auth: CmuxMobileAuthModel
    @State private var store: AppStore
    @State private var settings = SettingsStore()
    @State private var sidebar = SidebarModel()
    /// The app's keyboard notifications, for every keyboard-pinned composer.
    @State private var keyboard = MobileKeyboardFrameTracker()
    @State private var launchFinished = false
    @State private var previewSweepStarted = false
    /// Live data from sign-in on (setup included); nil in mock mode.
    @State private var live: LiveCoordinator?
    /// Setup's steps, fixed once the team list has loaded so a Mac appearing
    /// mid-setup does not swap the page under the user.
    @State private var setupPlan: [SetupFlow.Step]?
    /// Whether setup asks for notifications (a push build the system has not
    /// asked yet); nil until known.
    @State private var asksNotifications: Bool?
    /// The launch handed off straight to Welcome: Welcome is cut in (it
    /// redraws the launch mark and plays its intro) instead of crossfading.
    /// Fixed for the session, so a Welcome rebuilt mid-intro keeps playing;
    /// cleared on sign-out, where Welcome crossfades in, settled.
    @State private var welcomeCut = false
    @AppStorage("cmuxMobile.setupComplete") private var setupComplete = false
    /// The account whose preferences are live (`AccountPreferences`); sign-out
    /// puts them away under it.
    @State private var accountUserID: String?
    /// A pairing code opened while signed out: applied once the account's live data starts.
    @State private var heldInvite: PairInvite?
    /// The signed-in shell's one model, kept across this view's updates (`ShellView.init`).
    @State private var shellModel = KeptModel<ShellModel>()
    private let options: ShellLaunchOptions

    public init(auth: CmuxMobileAuthModel, store: AppStore, options: ShellLaunchOptions = ShellLaunchOptions()) {
        _auth = State(initialValue: auth)
        // Live auth: teams, Macs and workspaces come only from Stack and the
        // Mac (the sample data stays only for mock mode).
        if !auth.isMock {
            store.teams = []
            store.activeTeamID = ""
            store.workspaces = []
        }
        _store = State(initialValue: store)
        self.options = options
    }

    private enum Destination: Hashable { case welcome, setup, shell }

    private var destination: Destination {
        guard auth.isSignedIn else { return .welcome }
        return accountSetupComplete && !options.forceSetup ? .shell : .setup
    }

    /// Setup done for the signed-in account. Right after sign-in, before its
    /// preferences are live, it reads the account's record, so the same
    /// account signing in again never sees setup flash in.
    private var accountSetupComplete: Bool {
        guard !auth.isMock, let id = auth.user?.id, accountUserID != id else { return setupComplete }
        return AccountPreferences.standard.value("cmuxMobile.setupComplete", userID: id) as? Bool ?? false
    }

    public var body: some View {
        ZStack {
            theme.colors.bg.color.ignoresSafeArea()
            if launchFinished {
                Group {
                    switch destination {
                    case .welcome:
                        WelcomeView(auth: auth, playsLaunchIntro: welcomeCut, initialEmail: options.initialEmail)
                    case .setup:
                        SetupFlow(
                            steps: setupSteps, auth: auth, store: store,
                            signOut: { Task { await auth.signOut() } },
                            teamPicked: { _ in live?.activeTeamChanged() },
                            personalPicked: { live?.selectPersonal() },
                            teamCreated: teamCreated
                        ) {
                            setupComplete = true
                            theme.haptics.success()
                        }
                    case .shell:
                        ShellView(store: store, auth: auth, settings: settings, sidebar: sidebar, live: live, options: options, kept: shellModel)
                    }
                }
                // The launch-to-Welcome swap is a cut on both sides (an
                // animation attached to a transition ignores the cut's
                // transaction); every other swap crossfades, Welcome's exit
                // after sign-in included.
                .transition(welcomeCut && destination == .welcome
                    ? .asymmetric(insertion: .identity, removal: .opacity.animation(theme.motion.gentle.animation))
                    : .opacity.animation(theme.motion.gentle.animation))
            } else {
                // Welcome redraws this mark on its first frame and animates it
                // from there, so on that path the swap is a true cut: an
                // animated removal would leave a second, fading chevron behind
                // the welcome (an animation attached to a transition runs even
                // in a `disablesAnimations` transaction).
                LaunchMarkView()
                    .ignoresSafeArea()
                    .transition(destination == .welcome
                        ? .identity
                        : .opacity.combined(with: .scale(scale: 0.92)).animation(theme.motion.snap.animation))
            }
        }
        .animation(theme.motion.gentle.animation, value: destination)
        .environment(\.mobileKeyboardFrameTracker, keyboard)
        // Settings → Require Face ID (audit B11).
        .cmuxMobileAppLock(enabled: settings.requireFaceID)
        .task {
            guard !previewSweepStarted else { return }
            previewSweepStarted = true
            // A one-shot launch cleanup; active downloads/viewers are protected by
            // the store's ownership registry even when startup races a preview.
            await Task.detached(priority: .utility) {
                ManagedPreviewFile.removeStaleCopies()
            }.value
        }
        .task(id: auth.isResolved) {
            guard auth.isResolved, !launchFinished else { return }
            if !auth.isSignedIn, !auth.isMock { AccountSignOut().settleLaunchSignedOut() }
            syncTeams()
            if destination == .welcome {
                // Welcome draws the launch mark itself on its first frame and
                // animates it from there, so the swap must not fade either side.
                var cut = Transaction()
                cut.disablesAnimations = true
                withTransaction(cut) {
                    welcomeCut = true
                    launchFinished = true
                }
            } else {
                withAnimation(theme.motion.gentle.animation) { launchFinished = true }
            }
            #if DEBUG
            if options.setupPairDemo { await runSetupPairDemo() }
            #endif
        }
        // Signed in (or out): live data and the team list follow the account.
        .task(id: auth.isResolved ? auth.user?.id : nil) {
            // A reply a cold background launch is sending holds the device's one
            // signaling socket: let it finish before this coordinator dials.
            await PushReplies.shared.headlessFinished()
            accountChanged()
            await auth.loadTeams()
        }
        // The account's own preferences (setup done, its Mac per team, last
        // tab) come back before the first frame of its session, so the same
        // account signing in again skips setup (verify/persistence.md).
        .onChange(of: auth.isResolved ? (auth.isSignedIn ? auth.user?.id : "") : nil, initial: true) { _, id in
            guard auth.isResolved, !auth.isMock else { return }
            // A restored session publishes the active push account too. A
            // signed-out launch removes the old marker while retaining keys.
            PushActiveAccountMirror.shared.update(userID: id?.isEmpty == true ? nil : id)
            guard let id, !id.isEmpty else { return }
            AccountPreferences.standard.activate(userID: id)
            accountUserID = id
        }
        .onChange(of: auth.teamList) { _, _ in syncTeams() }
        // A Mac's pairing code from the Camera (`cmux-next://pair?…`); never logged, it holds a token.
        // Any other cmux link (`cmux://tab/…`, Safari, Messages, Notes) opens what it names.
        .onOpenURL { url in
            if let link = CmuxLink(url: url) { return NotificationRouter.shared.open(link: link) }
            guard let invite = PairInvite(url: url) else { return }
            if let live { live.accept(invite) } else { heldInvite = invite }
        }
        // A universal link (`https://cmux.com/link/…`, `/deeplink/agent`, a cloud group's page).
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL, let link = CmuxLink(url: url) else { return }
            NotificationRouter.shared.open(link: link)
        }
        .onChange(of: auth.teamList.phase, initial: true) { _, _ in planSetup() }
        .onChange(of: asksNotifications) { _, _ in planSetup() }
        .task(id: auth.isSignedIn) {
            guard auth.isSignedIn else { return }
            asksNotifications = await SetupFlow.asksForNotifications()
        }
        .onChange(of: auth.isSignedIn) { _, signedIn in
            if signedIn { theme.haptics.success() } else { signedOut() }
        }
        .onChange(of: settings.appearance, initial: true) { _, mode in
            applyAppearance(mode)
        }
    }

    private var setupSteps: [SetupFlow.Step] {
        if options.setupPairDemo { return [.pairMac, .notifications] }
        // Until the team list loads, the team step shows its loading state
        // (and a failed list still lets the user choose Personal).
        return setupPlan ?? [.team, .pairMac] + (asksNotifications == true ? [.notifications] : [])
    }

    /// Fixes setup's steps once the account's teams are known.
    private func planSetup() {
        guard auth.teamList.isLoaded, setupPlan == nil, let asksNotifications else { return }
        var steps: [SetupFlow.Step] = []
        let count = auth.isMock ? store.teams.count : auth.teamList.teams.count
        if count != 1 { steps.append(.team) }
        if !(store.activeTeam?.macs.contains(where: \.isOnline) ?? false) { steps.append(.pairMac) }
        if asksNotifications { steps.append(.notifications) }
        setupPlan = steps
        // Nothing to set up (one team, a Mac online, notifications decided).
        if steps.isEmpty, destination == .setup { setupComplete = true }
    }

    private func syncTeams() {
        let teams = auth.teams
        log.info("Stack teams: \(teams.count, privacy: .public)")
        if let live {
            // Live: Macs come from the cmux-next-ios service, never the samples. An
            // account with no team uses its personal space, once that is known.
            guard auth.teamList.isLoaded else { return }
            live.applyAccountTeams(teams, selectedID: auth.selectedTeamID)
            return
        }
        guard !teams.isEmpty else { return }
        if auth.isMock {
            store.applyAccountTeams(teams, selectedID: auth.selectedTeamID)
        } else {
            store.applyLiveTeams(teams, selectedID: auth.selectedTeamID)
        }
    }

    private func teamCreated(_ team: AppStore.AccountTeam) {
        guard let live else {
            store.applyAccountTeams([team], selectedID: team.id)
            return
        }
        var teams = auth.teams
        if !teams.contains(where: { $0.id == team.id }) { teams.append(team) }
        live.applyAccountTeams(teams, selectedID: team.id)
    }

    /// Every sign-out path (setup's footer, Settings → Sign out, a session the
    /// service ended) lands here: live data stops; the account's teams, Macs,
    /// workspaces, Feed and snapshots leave the screen and the disk; its
    /// preferences are put away under its id; and Welcome crossfades in,
    /// already settled (its intro plays once per cold launch).
    ///
    /// This iPhone keeps its identity for the account: device ids, Secure
    /// Enclave keys and pinned Macs, so its Macs' approvals still hold when the
    /// same account signs in again (verify/persistence.md). Removing it from
    /// the Macs is its own action (Settings → Devices).
    private func signedOut() {
        // Unexpected session loss (without the manual sign-out hook) also
        // makes queued notifications inert on this device.
        if !auth.isMock { PushActiveAccountMirror.shared.update(userID: nil) }
        // A live Chief call (even minimized) ends with the account; a call asked for while signed out is dropped.
        ChiefLiveCall.shared.signedOut()
        ChiefCallLauncher.shared.cancelPending()
        // A pending approval/reply or notification route belongs to the old
        // account, including if sign-out came from an expired server session.
        PushReplies.shared.signedOut()
        let ending = live
        live = nil
        shellModel.discard { $0.cloudChats = nil }
        setupPlan = nil
        asksNotifications = nil
        if auth.isMock {
            // The next account starts on Home, not in this one's workspace.
            LastOpenMemory.standard.save(nil)
            setupComplete = false
        } else {
            AccountSignOut().signedOut(userID: accountUserID, session: ending)
            accountUserID = nil
        }
        store.resetForSignOut()
        // The chats loaded in this launch go too: the next background would save them again.
        AgentSessionDirectory.shared.removeAll()
        // No account's chat text stays for notification previews, and no reply or photo waits (review L4).
        PushRetryStore.app?.removeAll()
        // The App Group is resolved and emptied off the main thread, after any snapshot save in flight.
        let snapshotsCleared = PushSnapshots.clearForSignOut()
        PushReplies.shared.clearOutboxForSignOut(after: snapshotsCleared)
        welcomeCut = false
        log.info("signed out: account state reset, device identity kept")
    }

    /// Starts live data for a signed-in account (before setup, so setup sees
    /// real Macs) and stops it on sign-out.
    private func accountChanged() {
        guard let user = auth.user, auth.isSignedIn else {
            live?.stop()
            live = nil
            setupPlan = nil
            return
        }
        #if DEBUG
        if auth.isMock, store.teams.isEmpty {
            // Mock mode signed in again after a sign-out: the sample data comes back.
            let sample = AppStore.mock()
            store.teams = sample.teams
            store.activeTeamID = sample.activeTeamID
            store.workspaces = sample.workspaces
        }
        #endif
        guard live == nil, !auth.isMock, let base = auth.apiBaseURL else { return }
        let coordinator = LiveCoordinator.forAccount(auth: auth, user: user, base: base, store: store, transport: settings.transport)
        coordinator.onFollow = { [auth] teamID in
            guard !teamID.hasPrefix("personal-") else { return }
            Task { await auth.selectTeam(teamID) }
        }
        live = coordinator
        PushReplies.shared.attach(live: coordinator)
        // Before the session ends: stop pushes to this phone. The Macs keep
        // their approval of it (verify/persistence.md).
        auth.willSignOut = AccountSignOut().willSignOut {
            // Disarm queued replies before the sign-out network work suspends.
            PushReplies.shared.signedOut()
            // Withhold content before network sign-out can leave this device.
            // The marker lives independently of the pairing keys we retain.
            await PushActiveAccountMirror.shared.clearBeforeSignOut()
            await PushRegistration.shared.unregister()
            // Screen Sharing: end the session on screen and sign this phone out of the device hub
            // while the account can still reach it (docs/device-hub/PROTOCOL.md, sign-out).
            await ScreenSharingService.current?.signOutBeforeSessionEnds()
        }
        log.info("live data on \(base.host() ?? "", privacy: .public)")
        syncTeams()
        if let invite = heldInvite {
            heldInvite = nil
            coordinator.accept(invite)
        }
        #if DEBUG
        // Test-only (compiled out of Release): the pair-e2e rig (scripts/ci/cmux_next_pair_e2e.py)
        // hands this launch a Mac's pairing code in its environment, taken as a scanned code is
        // (.onOpenURL above). A simulator asks "Open in cmux?" for `simctl openurl`, and nothing on
        // a CI Mac answers it. Never logged; the code's token is single use and expires in minutes.
        if let text = ProcessInfo.processInfo.environment["CMUX_MOBILE_PAIR_URL"], let invite = PairInvite(text: text) {
            coordinator.accept(invite)
        }
        #endif
    }

    #if DEBUG
    /// `-cmux-mobile-setup-pair`: the active team's Macs vanish, then a Mac comes
    /// online 4 s in (recording pace, not synchronization). With
    /// `-cmux-mobile-setup-pair-elsewhere` it comes online in another team, and the
    /// phone follows it there as live discovery does. With
    /// `-cmux-mobile-setup-pair-other-account` no Mac uses the account at all.
    private func runSetupPairDemo() async {
        guard let index = store.teams.firstIndex(where: { $0.id == store.activeTeamID }) else { return }
        let macs = store.teams[index].macs
        if ProcessInfo.processInfo.arguments.contains("-cmux-mobile-setup-pair-other-account") {
            // No Mac uses this account anywhere: the setup step says so.
            for i in store.teams.indices { store.teams[i].macs = [] }
            store.accountMacCount = 0
            return
        }
        let elsewhere = ProcessInfo.processInfo.arguments.contains("-cmux-mobile-setup-pair-elsewhere")
        if elsewhere {
            for i in store.teams.indices { store.teams[i].macs = [] }
        } else {
            store.teams[index].macs = []
        }
        try? await Task.sleep(for: .seconds(4))
        guard elsewhere else {
            store.teams[index].macs = macs
            return
        }
        guard let other = store.teams.first(where: { $0.id != store.activeTeamID }) else { return }
        let mac = macs.first(where: \.isOnline) ?? MacDevice(id: "mac-elsewhere", name: "Aziz's MacBook Pro", isOnline: true)
        let found = [DiscoveredMac(id: mac.id, name: mac.name, isOnline: true, teamID: other.id)]
        store.mergeDiscoveredMacs(found)
        if let team = store.teamToFollow(found, previouslyOnline: nil) {
            log.info("setup demo: following the Mac to \(team.name, privacy: .public)")
            store.selectTeam(team.id)
        }
    }
    #endif

    private func applyAppearance(_ mode: AppearanceMode) {
        let style: UIUserInterfaceStyle = switch mode {
        case .light: .light
        case .dark: .dark
        case .system: .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

/// One model, built by the first caller and handed to every later one until `discard()`.
@MainActor
final class KeptModel<Model: AnyObject> {
    private var kept: Model?

    func model(make: () -> Model) -> Model {
        if let kept { return kept }
        let made = make()
        kept = made
        return made
    }

    func discard(cleanup: (Model) -> Void = { _ in }) {
        if let kept { cleanup(kept) }
        kept = nil
    }
}

/// The signed-in shell: the UIKit drawer container with the team sidebar under
/// a four-tab `TabView`.
struct ShellView: View {
    @State private var shell: ShellModel
    @State private var inviteEmail = ""
    private let options: ShellLaunchOptions
    /// RootView's coordinator; it can arrive after the shell is built.
    private let live: LiveCoordinator?

    /// RootView re-creates this view on every update, and each creation runs this initializer. The
    /// model is built (and wired to `live`, which writes the shared Feed and browser wiring) once, by
    /// the first creation; later ones get the same model, so no throwaway model overwrites that wiring
    /// with closures that die with it.
    init(store: AppStore, auth: CmuxMobileAuthModel, settings: SettingsStore, sidebar: SidebarModel, live: LiveCoordinator?,
         options: ShellLaunchOptions, kept: KeptModel<ShellModel>) {
        let shell = kept.model {
            let shell = ShellModel(store: store, auth: auth, settings: settings, sidebar: sidebar)
            shell.attach(live: live)
            #if DEBUG
            // Synthetic connection metadata for captures; never reads a real machine.
            if auth.isMock, UserDefaults.standard.bool(forKey: "cmux-mobile-link-status-demo"),
               let mac = store.activeTeam?.macs.first {
                let phase = LinkMachine.Phase.connected(.wireGuard, .direct, rttMillis: 27)
                let status = phase.statusLine(macName: mac.name, media: .up(.turn, rttMillis: 30))
                let detail = phase.diagnosticLine(macName: mac.name, media: .up(.turn, rttMillis: 30))
                if store.macLinkStatus[mac.id] != status { store.macLinkStatus[mac.id] = status }
                if store.macLinkDiagnostics[mac.id] != detail { store.macLinkDiagnostics[mac.id] = detail }
            }
            #endif
            if let tab = options.initialTab.flatMap(RootTab.init(rawValue:)) { shell.tab = tab }
            if let page = options.settingsPage.flatMap(SettingsRoute.init(name:)) {
                shell.tab = .settings
                shell.settingsPath = [page]
            }
            return shell
        }
        _shell = State(initialValue: shell)
        self.options = options
        self.live = live
    }

    var body: some View {
        SidebarContainer(
            model: shell.sidebar,
            sidebar: TeamSidebar(store: shell.store, shell: shell, sidebar: shell.sidebar),
            content: ShellTabs(shell: shell).environment(shell.store)
        )
        .ignoresSafeArea()
        .cmuxMobileToast($shell.toast)
        .modifier(LiveCallHost(shell: shell))
        .sheet(item: $shell.shareURL) { item in
            ShareSheet(url: item.url).presentationDetents([.medium, .large])
        }
        .sheet(item: $shell.cloudChats) { item in
            CloudChatsScreen(shell: shell, attention: item.attention)
        }
        .sheet(item: $shell.editingTeam) { team in
            TeamAppearanceEditor(team: team) { shell.saveAppearance($0, for: team) }
        }
        .sheet(item: $shell.connectedDevices) { item in
            TerminalConnectedDevicesSheet(live: item.live, macID: item.macID, surface: item.surface, service: shell.sizingService)
                .presentationDetents([.medium, .large])
        }
        .alert("Invite to \(shell.invitingTeam?.name ?? "team")", isPresented: Binding(
            get: { shell.invitingTeam != nil },
            set: { if !$0 { shell.invitingTeam = nil } }
        )) {
            TextField("Email", text: $inviteEmail)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            Button("Cancel", role: .cancel) { inviteEmail = "" }
            Button("Send") {
                if let team = shell.invitingTeam { shell.sendInvite(email: inviteEmail, to: team) }
                inviteEmail = ""
            }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("They'll get an email invitation to join.")
        }
        .onChange(of: shell.live?.followed) { _, followed in
            guard let followed else { return }
            // Followed to another team: the old team's screens close, as on a tap.
            shell.closeTeamScreens()
            shell.toast = CmuxMobileToast(symbol: "desktopcomputer", text: "\(followed.macName) is in \(followed.teamName). Switched to it.")
        }
        .modifier(LinkSettingsObserver(shell: shell))
        // Notification taps: open now, or once the Mac's tree places the tab.
        .onChange(of: NotificationRouter.shared.pending, initial: true) { _, route in
            guard let route else { return }
            if shell.open(route) { NotificationRouter.shared.opened() }
        }
        .modifier(NotificationRouteObserver(shell: shell))
        // A named Home conversation link may arrive before the Mac's Home
        // rows or Cloud Chief are loaded; continue the pending route as those
        // owners publish their identities, instead of opening another Chief.
        .onChange(of: MacHomeFeed.shared.rows) { _, _ in
            if let route = NotificationRouter.shared.pending, shell.open(route) { NotificationRouter.shared.opened() }
        }
        .onChange(of: ChiefSources.shared.cloud.conversationID) { _, _ in
            if let route = NotificationRouter.shared.pending, shell.open(route) { NotificationRouter.shared.opened() }
        }
        .onChange(of: ChiefSources.shared.mac.conversationID) { _, _ in
            if let route = NotificationRouter.shared.pending, shell.open(route) { NotificationRouter.shared.opened() }
        }
        // Design/terminal P10: remember where the user is; finish a launch
        // restore once the workspace is listed (or its Mac says it is gone).
        // Back to the workspace and tab that were open (P10), once, on the
        // model SwiftUI keeps. Not from `init`: RootView re-creates this view
        // (and a throwaway model) on every update, and a restore there wrote
        // the shared store from each one: an endless update loop at launch.
        // A tapped notification decides where the app opens instead.
        .onAppear {
            if options.restoresLastLocation, NotificationRouter.shared.pending == nil { shell.beginRestore() }
        }
        .onChange(of: shell.lastOpenLocation) { _, location in
            shell.locationChanged(location)
        }
        .modifier(WorkspaceDataObserver(shell: shell))
        .onChange(of: pushKinds, initial: true) { _, preferences in
            PushRegistration.shared.setPreferences(preferences)
        }
        .onAppear {
            NotificationRouter.shared.isShowing = { [weak shell] route in shell?.isShowing(route) ?? false }
            // On the model SwiftUI keeps (init also builds throwaway ones).
            FeedRouting.shared.openTerminal = { [weak shell] item in shell?.openTerminal(item) }
        }
        .onChange(of: live.map(ObjectIdentifier.init)) { _, _ in
            shell.attach(live: live)
            // A tapped notification that waited for the link (cold launch) opens now, or waits for its Mac's tree.
            if let route = NotificationRouter.shared.pending, shell.open(route) { NotificationRouter.shared.opened() }
        }
        .task {
            #if DEBUG
            if CommandLine.arguments.contains("-cmux-mobile-team-transparent") { DemoDriver(shell: shell).seedTransparentTeams() }
            KeyboardPinTrace.startIfRequested()
            #endif
            if options.sidebarOpen { shell.sidebar.open() }
            #if DEBUG
            if let demo = options.demo { await DemoDriver(shell: shell).run(demo) }
            await ListStressRig.runIfConfigured(shell: shell)
            await DebugLaunch.run(selectTab: { shell.tab = $0 })
            #endif
        }
    }
}

/// A tapped notification's route that waits (review #4): opened as the Feed
/// once its budget ends, dropped when the person goes elsewhere. Its own
/// modifier, so ShellView's chain stays small enough to type-check.
private struct NotificationRouteObserver: ViewModifier {
    let shell: ShellModel

    func body(content: Content) -> some View {
        content
            .onChange(of: NotificationRouter.shared.expired) { _, _ in
                if let route = NotificationRouter.shared.pending, shell.open(route) { NotificationRouter.shared.opened() }
            }
            .onChange(of: shell.tab) { _, tab in
                if tab != .feed { NotificationRouter.shared.userNavigated() }
            }
    }
}

/// Follows the workspaces and the Macs' data (restore, terminal pages, a
/// waiting notification route). Its own modifier: the reads re-run only this
/// modifier's body, not ShellView's, which rebuilt the drawer, the tabs and
/// every bar's toolbar on each Mac tree update.
private struct WorkspaceDataObserver: ViewModifier {
    let shell: ShellModel

    func body(content: Content) -> some View {
        content
            .onChange(of: shell.store.activeWorkspaces) { _, _ in
                shell.continueRestore()
            }
            .onChange(of: shell.store.macData) { _, _ in
                shell.continueRestore()
                // Its Mac answered or went away: open the route, or the Feed.
                if let route = NotificationRouter.shared.pending, shell.open(route) { NotificationRouter.shared.opened() }
            }
            .onChange(of: shell.live?.workspaces.tree?.surfaces ?? [:]) { _, _ in
                shell.terminalTabs.liveDataChanged()
            }
            .onChange(of: shell.store.workspaces) { _, _ in
                // A terminal page shown before the tree arrived (a launch
                // restore) attaches now (design/terminal R1-0).
                shell.terminalTabs.liveDataChanged()
                // A tapped notification waits for its Mac's tree (a cold launch), then opens.
                if let route = NotificationRouter.shared.pending, shell.open(route) { NotificationRouter.shared.opened() }
            }
    }
}

/// Hands the link the Settings transport and developer path choices, and
/// the app's return to the foreground. Its own modifier so ShellView's
/// chain stays small enough to type-check in a Release build.
private struct LinkSettingsObserver: ViewModifier {
    let shell: ShellModel
    @Environment(\.scenePhase) private var scenePhase
    /// Settings → Developer "Relay only"; read through `DeveloperOptions`,
    /// which ignores it outside DEBUG builds.
    @AppStorage(DeveloperOptions.relayOnlyKey) private var relayOnlyPreference = false
    /// Settings → Developer "Block UDP"; read through `DeveloperOptions`.
    @AppStorage(DeveloperOptions.blockUDPKey) private var blockUDPPreference = false

    func body(content: Content) -> some View {
        content
            .onChange(of: shell.settings.transport) { _, transport in
                shell.live?.setTransport(transport.link)
            }
            .onChange(of: relayOnlyPreference) { _, _ in
                shell.live?.setRelayOnly(DeveloperOptions.relayOnly)
            }
            .onChange(of: blockUDPPreference) { _, _ in
                shell.live?.setBlockUDP(DeveloperOptions.blockUDP)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    shell.live?.foreground()
                    // The content extension's replies, and those waiting for the app.
                    PushReplies.shared.drainOutbox()
                }
                // Inactive (Control Center, a banner, the app switcher's first
                // moment) still shows the page: only the background hides it.
                // Hidden pages stop painting on the Mac and give up the lane.
                StreamedBrowserDirectory.shared.setAppActive(phase != .background)
                // The notification preview shows these chats' last messages.
                if phase == .background {
                    shell.live?.background()
                    Task { await PushSnapshots().save() }
                }
            }
    }
}

extension ShellView {
    /// What Settings → Notifications asks the service for.
    var pushKinds: PushRegistration.Preferences {
        PushRegistration.Preferences(kinds: shell.settings.notifyLevel.kinds, mutedMacs: shell.settings.notifyMutedMacs,
                                     previews: shell.settings.notifyPreviews)
    }
}

extension CmuxMobileModel.TransportKind {
    /// The link layer's transport for the Settings choice.
    var link: CmuxMobileTransport.TransportKind { self == .webrtc ? .webRTC : .wireGuard }
}

/// The live Chief call over the signed-in shell: the full-screen call, the
/// pill while it is minimized, and every Call Chief entry point
/// (``ChiefCallLauncher``) routed to ``ShellModel/callChief()``.
private struct LiveCallHost: ViewModifier {
    let shell: ShellModel
    private let call = ChiefLiveCall.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let session = call.session, call.isMinimized, !session.hasEnded {
                    LiveCallPill(call: call, session: session)
                        .padding(.top, 2)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(theme.motion.snappy.animation, value: call.isMinimized)
            .fullScreenCover(isPresented: Binding(
                get: { call.showsScreen },
                set: { if !$0 { call.isMinimized = true } }
            )) {
                if let session = call.session {
                    LiveCallScreen(call: call, session: session) { shell.openChiefCallSettings() }
                }
            }
            .task(id: shell.auth.isSignedIn ? shell.auth.user?.id : nil) {
                let user = shell.auth.isSignedIn ? shell.auth.user : nil
                call.configure(store: shell.store, accountID: user?.id,
                               userName: user?.name.split(separator: " ").first.map(String.init))
                ChiefCallLauncher.shared.handler = { [shell] in shell.callChief() }
            }
            .onDisappear { ChiefCallLauncher.shared.handler = nil }
    }
}

/// Exactly four tabs: Home, Workspaces, Feed, Settings. The selected tab is
/// `label` (neutral accent), never blue. The bar stays fully visible while
/// content scrolls: it never minimizes to the selected tab's pill. Whether it
/// shows at all is ``ShellModel/showsTabBar(on:)``, set here on each tab's
/// content, outside its stack.
struct ShellTabs: View {
    let shell: ShellModel

    var body: some View {
        @Bindable var shell = shell
        TabView(selection: $shell.tab) {
            Tab("Home", systemImage: "house", value: RootTab.home) {
                HomeScreen(shell: shell)
                    .modifier(TabBarVisibility(shell: shell, tab: .home))
                    .modifier(TabBarProbeHost())
            }
            Tab("Workspaces", systemImage: "square.stack.3d.up", value: RootTab.workspaces) {
                WorkspacesScreen(shell: shell)
                    .modifier(TabBarVisibility(shell: shell, tab: .workspaces))
                    .modifier(TabBarProbeHost())
            }
            .badge(shell.store.attentionCount)
            Tab("Feed", systemImage: "bubble.left.and.text.bubble.right", value: RootTab.feed) {
                FeedTabContent(shell: shell)
                    .modifier(TabBarVisibility(shell: shell, tab: .feed))
                    .modifier(TabBarProbeHost())
            }
            .badge(FeedStore.shared.needsYouCount)
            Tab("Settings", systemImage: "gearshape", value: RootTab.settings) {
                SettingsScreen(
                    auth: shell.auth,
                    store: shell.store,
                    settings: shell.settings,
                    path: $shell.settingsPath,
                    scrollRequest: shell.settingsScrollTarget,
                    directory: shell.deviceDirectory,
                    sizing: shell.sizingService,
                    callChief: { shell.callChief() },
                    screenSharing: shell.screenSharing,
                    inviteToTeam: { shell.invite(to: $0) },
                    saveAppearance: { shell.saveAppearance($0, for: $1) }
                ) {
                    SidebarToolbarItem(sidebar: shell.sidebar)
                }
                .modifier(TabBarVisibility(shell: shell, tab: .settings))
                .modifier(TabBarProbeHost())
            }
        }
        .tabBarMinimizeBehavior(.never)
        .tint(theme.colors.label.color)
        .cmuxMobileSensoryFeedback(.selection, trigger: shell.tab)
    }
}

/// The UI tests' tab bar probe (``TabBarProbe``) in a tab's content, outside
/// its stack; nothing outside DEBUG builds launched with its argument.
private struct TabBarProbeHost: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        content.overlay(alignment: .topLeading) { TabBarProbe() }
        #else
        content
        #endif
    }
}

/// The Feed tab's content. `ShellTabs` re-renders on every Mac tree update
/// (its badges read the workspaces); this view's only input is the shell
/// model, so the Feed screen is not rebuilt with it.
private struct FeedTabContent: View {
    let shell: ShellModel

    var body: some View {
        @Bindable var shell = shell
        CmuxMobileFeed.FeedScreen(path: $shell.feedPath, reconnect: {
            await shell.live?.reconnectFeeds()
        }) { SidebarToolbarItem(sidebar: shell.sidebar) }
    }
}

#if DEBUG
/// DEBUG launch arguments: `-CmuxMobileDemo chat-feed` runs the Feed + agent chat demo driver;
/// `-CmuxMobileDemo acp-parity` the Feed swipe, artifacts, subagents, checkpoints and handoff driver.
struct DebugLaunch {
    @MainActor
    static func run(selectTab: (RootTab) -> Void) async {
        let arguments = ProcessInfo.processInfo.arguments
        let name: String
        if let index = arguments.firstIndex(of: "-CmuxMobileDemo"), arguments.indices.contains(index + 1) {
            name = arguments[index + 1]
        } else if let picked = DeveloperOptions.launchDemo {
            name = picked
        } else {
            return
        }
        switch name {
        case "chat-feed":
            selectTab(.feed)
            await FeedDemoScript().run()
        case "acp-parity":
            selectTab(.feed)
            await ParityDemoScript().run()
        default:
            break
        }
    }
}
#endif
#endif
