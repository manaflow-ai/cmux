#if os(iOS)
import CmuxDeviceHub
import CmuxMobileAgentChat
import CmuxMobileAuth
import CmuxMobileBrowserStream
import CmuxMobileChief
import CmuxMobileDesign
import CmuxMobileFeed
import CmuxMobileLive
import CmuxMobileModel
import CmuxMobileNotifications
import CmuxMobileScreenSharing
import CmuxMobileSettings
import CmuxMobileTerminal
import CmuxMobileVoice
import CmuxMobileWorkspaces
import OSLog
import Observation
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard
private let shellLog = Logger(subsystem: "dev.cmux.mobile", category: "shell")

/// Root tabs. Exactly four; there is no Search tab.
enum RootTab: String, Hashable, CaseIterable {
    case home, workspaces, feed, settings
}

/// Shell-level state and actions shared by the tabs and the sidebar.
@MainActor
@Observable
final class ShellModel {
    let store: AppStore
    let auth: CmuxMobileAuthModel
    let settings: SettingsStore
    @ObservationIgnored let terminalTabs = GhosttyTerminalTabContent()
    /// The Mac filter Workspaces and Home share (remembered per team).
    @ObservationIgnored let macFilter = MacFilter()
    let sidebar: SidebarModel
    /// New workspaces: the linked Mac's daemon once live data starts; before
    /// that nothing can be created (the mock only in DEBUG mock mode).
    let creator: WorkspaceCreator
    #if DEBUG
    /// The mock backend (DEBUG demos make it refuse once).
    let mockCreation: MockWorkspaceCreationBackend
    #endif
    /// The backend with no live data.
    private let offlineCreation: any WorkspaceCreationBackend

    var tab: RootTab = .home {
        didSet {
            updateInteractiveOpen()
            updateShownMacs()
        }
    }
    var homePath = NavigationPath() { didSet { updateInteractiveOpen() } }
    /// Typed: a workspace page must not nest a SwiftUI NavigationStack (the
    /// terminal tab hosts its own page), or SwiftUI traps with
    /// `comparisonTypeMismatch` when the nested stack joins this path.
    var workspacesPath: [Workspace] = [] {
        didSet {
            updateInteractiveOpen()
            updateShownMacs()
        }
    }
    var feedPath: [AgentChatDestination] = [] { didSet { updateInteractiveOpen() } }
    var settingsPath: [SettingsRoute] = [] { didSet { updateInteractiveOpen() } }

    var toast: CmuxMobileToast?
    var editingTeam: Team?
    /// Live data (signed in for real with a `cmux-mobile-api` base URL); nil in mock mode.
    /// The same load is retried from Workspaces; mock recovery reloads its fixture.
    func retryWorkspaces() async {
        if let live { live.retry(); return }
        #if DEBUG
        if mockMode {
            let loaded = AppStore.mock()
            store.teams = loaded.teams
            store.workspaces = loaded.workspaces
            store.teamDataState = .loaded
        }
        #endif
    }

    var live: LiveCoordinator?
    /// Settings → Connection's device list and account deletion (live mode).
    private(set) var deviceDirectory: (any SettingsDeviceDirectory)?
    /// The Macs' terminal sizing policies (Settings and Connected Devices).
    var sizingService: (any TerminalSizingService)? { live }
    /// Screen Sharing with the account's Macs while signed in (Settings → Screen Sharing).
    private(set) var screenSharing: ScreenSharingService?
    /// DEBUG mock mode (Settings → Developer → Mock): sample content only.
    let mockMode: Bool
    /// Send Message… on a workspace or a tab: the message to the Chief being written.
    var messagingChief: ChiefMessageAbout?
    /// The team an email invite is being written for (live mode).
    var invitingTeam: Team?
    var isFetchingInvite = false
    var shareURL: ShareItem?
    /// Connected Devices for the terminal on screen (its title menu).
    var connectedDevices: ConnectedDevicesItem?
    var cloudChats: CloudChatsPresentation? {
        didSet { if cloudChats == nil { cloudMacID = nil } }
    }
    var cloudMacID: String? { didSet { updateShownMacs() } }

    struct CloudChatsPresentation: Identifiable {
        let id = UUID()
        let attention: CloudChatAttention?
    }
    /// Debug-driven scroll target for the Settings list.
    var settingsScrollTarget: String?
    /// Where the user was, kept across launches (design/terminal P10).
    @ObservationIgnored let lastOpen: LastOpenMemory
    /// A launch restore still waiting for its workspace to be listed.
    @ObservationIgnored private var pendingRestore: LastOpenLocation?
    /// One launch restore per model.
    @ObservationIgnored private var restoreAttempted = false
    /// A restored workspace whose Mac was not online yet: linked once it is (R1-0).
    @ObservationIgnored private var restoreLinkMac: String?

    struct ShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// One terminal's Connected Devices sheet.
    struct ConnectedDevicesItem: Identifiable {
        let id = UUID()
        let live: TerminalSizingLive
        let macID: String
        let surface: Int
    }

    init(store: AppStore, auth: CmuxMobileAuthModel, settings: SettingsStore, sidebar: SidebarModel, lastOpen: LastOpenMemory = .standard) {
        self.lastOpen = lastOpen
        self.store = store
        self.auth = auth
        self.settings = settings
        self.sidebar = sidebar
        terminalTabs.accountUserIDProvider = { [weak auth] in auth?.user?.id }
        // Mock content only in DEBUG mock mode (mock auth); a live account
        // never falls back to it.
        let mockMode = TerminalSessionChoice.mockCompiledIn && auth.isMock
        self.mockMode = mockMode
        #if DEBUG
        // `-cmux-mobile-mock-create-delay <seconds>` holds mock creations open, so
        // the list's pending row can be seen (verify/record-wsdesign.sh).
        let delay = UserDefaults.standard.double(forKey: "cmux-mobile-mock-create-delay")
        let mock = delay > 0 ? MockWorkspaceCreationBackend(latency: .seconds(delay)) : MockWorkspaceCreationBackend()
        mockCreation = mock
        // `-cmux-mobile-refuse-next-tab`: the next tab request is refused like the live report's
        // (the Mac's cwd policy), for the new-tab captures.
        if CommandLine.arguments.contains("-cmux-mobile-refuse-next-tab") {
            mock.failNext = "cwd is refused: a remote WebSocket connection may use only a known project or a configured webRoots folder"
        }
        offlineCreation = mockMode ? mock : UnavailableWorkspaceCreationBackend()
        #else
        offlineCreation = UnavailableWorkspaceCreationBackend()
        #endif
        creator = WorkspaceCreator(store: store, backend: offlineCreation)
        terminalTabs.mockDataEnabled = mockMode
        terminalTabs.macName = { [weak store] workspace in
            store?.teams.flatMap(\.macs).first { $0.id == workspace.macID }?.name
        }
        creator.onFailure = { [weak self] placeholder, message in
            self?.workspaceCreationFailed(placeholder, message: message)
        }
        ChiefMessenger.shared.compose = { [weak self] subject in self?.messagingChief = subject }
        creator.onManageFailure = { [weak self] _, what, message in
            self?.toast = CmuxMobileToast(symbol: "exclamationmark.circle", text: what)
            theme.haptics.error()
            shellLog.error("\(what, privacy: .public): \(message, privacy: .public)")
        }
    }

    /// Shows `workspace` in place of the one on screen (the Chats list's Open in New Workspace).
    /// The destination keeps its screen state at the same place in the path, so the path is
    /// emptied first and the workspace pushed on the next turn, as `openTerminal` does.
    func show(workspace: Workspace) {
        tab = .workspaces
        workspacesPath = []
        Task { @MainActor [weak self] in self?.workspacesPath = [workspace] }
    }

    /// New Agent Chat from Shortcuts, Siri or Spotlight (``AgentChatLauncher``): as the
    /// Workspaces menu's New Agent Chat, a workspace whose only tab is the Mac's default agent,
    /// in the most recent folder on the Mac new workspaces go to, opened with its composer up and
    /// `prompt` in it (sent when the person taps Send, as the Mac's quick composer's text is).
    func startAgentChat(prompt: String?) {
        guard let mac = creator.targetMac else {
            toast = CmuxMobileToast(symbol: "desktopcomputer", text: "Connect a Mac to start an agent chat")
            return
        }
        guard creator.options(on: mac.id).agents.contains(""),
              let workspace = creator.create(start: .agent(""), directory: creator.recentDirectories(on: mac.id).first, macID: mac.id) else {
            toast = CmuxMobileToast(symbol: "exclamationmark.circle", text: "\(mac.name) can't start an agent chat from here")
            return
        }
        AgentSessionDirectory.shared.newChatDraft = prompt
        show(workspace: workspace)
    }

    /// A terminal agent's Feed event: its workspace on Workspaces, at that
    /// terminal tab (as a tap on the workspace row with that tab does).
    func openTerminal(_ item: FeedItem) {
        guard let workspace = store.workspace(id: item.workspaceID) else {
            toast = CmuxMobileToast(symbol: "exclamationmark.circle", text: "That workspace is no longer open")
            return
        }
        store.noteOpened(tabID: item.tabID, in: workspace.id)
        store.markSeen(workspace.id)
        tab = .workspaces
        if workspacesPath.last?.id == workspace.id {
            // Its page is already up, on the tab it had: build it again on this tab.
            workspacesPath = []
            Task { @MainActor [weak self] in self?.workspacesPath = [workspace] }
        } else {
            workspacesPath = [workspace]
        }
        if let live, store.teams.flatMap(\.macs).contains(where: { $0.id == workspace.macID && $0.isOnline }) {
            live.select(macID: workspace.macID)
        }
    }

    /// Points terminal tabs and new workspaces at `live`, or back at the
    /// offline fallbacks when it is nil (the mocks only in DEBUG mock mode). RootView creates the coordinator when the account
    /// resolves, which can be after this shell was built (a restored session,
    /// a DEBUG auto sign-in), so this runs on every change, not once.
    func attach(live: LiveCoordinator?) {
        if self.live !== live, self.live != nil { terminalTabs.reset() }
        self.live = live
        deviceDirectory = live.map(LiveDeviceDirectory.init(live:))
        #if DEBUG
        if live == nil, mockMode { deviceDirectory = MockDeviceDirectory(store: store) }
        #endif
        live?.onMacRemoved = { [weak self] macID in self?.macRemoved(macID) }
        attachScreenSharing(signedIn: live != nil)
        updateShownMacs()
        if let live {
            // Tab ids repeat across Macs: every call names the tab's Mac, and
            // its session uses that Mac's link only.
            terminalTabs.reconnect = { [weak live] macID in live?.retry(macID: macID) }
            terminalTabs.sessionProvider = { [weak live] tab, macID in
                live?.terminalSession(tabID: tab.id, programName: tab.title, macID: macID)
            }
            terminalTabs.showConnectedDevices = { [weak self] session, macID in
                self?.connectedDevices = ConnectedDevicesItem(live: session.sizing, macID: macID, surface: session.surface)
            }
            terminalTabs.hasLiveSession = { [weak live] id, macID in live?.hasLiveSession(tabID: id, macID: macID) ?? false }
            terminalTabs.workspaceLookup = { [weak store] id in store?.workspace(id: id) }
            terminalTabs.artifactSourceProvider = { [weak live] tab, macID in live?.terminalArtifactSource(tabID: tab.id, macID: macID) }
            terminalTabs.uploaderProvider = { [weak live] tab, macID in live?.terminalUploader(tabID: tab.id, macID: macID) }
            terminalTabs.screenTextProvider = { [weak live] tab, macID in await live?.terminalScreenText(tabID: tab.id, macID: macID) }
            // Each change goes to its workspace's Mac over that Mac's own link.
            let backend = MultiMacWorkspaceBackend(coordinator: live)
            creator.backend = backend
            FeedRouting.shared.clearAllNotifications = { [weak live, weak backend] in
                // The Feed holds every linked Mac's terminal events: each clears its own.
                let macs = (live?.linkedMacIDs ?? []).filter { backend?.canClearNotifications(on: $0) == true }
                guard let backend, !macs.isEmpty else { throw WorkspaceCreationError("Not connected to a Mac") }
                for macID in macs { try await backend.clearAllNotifications(on: macID) }
            }
            FeedRouting.shared.markAllNotificationsRead = { [weak live, weak backend] in
                // Each linked Mac reads its own unread tabs, as its Mark All Notifications as Read.
                let macs = (live?.linkedMacIDs ?? []).filter { backend?.canClearNotifications(on: $0) == true }
                guard let backend, !macs.isEmpty else { return 0 }
                var read = 0
                for macID in macs { read += try await backend.markAllNotificationsRead(on: macID) }
                return read
            }
            // A Feed reply to a terminal agent goes to its own Mac's link, into that terminal.
            FeedRouting.shared.replyToTerminal = { [weak live] item, text in
                guard let feed = live?.terminalFeed(macID: item.macID) else { return "Not connected to that Mac." }
                return await feed.reply(itemID: item.id, text: text)
            }
            StreamedBrowserDirectory.shared.opener = { [weak live] in await live?.browserLink() }
            StreamedBrowserDirectory.shared.macOpener = { [weak live] macID in await live?.browserLink(macID: macID) }
            creator.onTabResolved = { from, to in StreamedBrowserDirectory.shared.rename(tab: from, to: to) }
            // Browser tabs opened on this iPhone follow the Macs' tab lists.
            StreamedBrowserDirectory.shared.tabsRetained = { NativeBrowserTabs.shared.retain(tabs: $0) }
            StreamedBrowserDirectory.shared.tabRenamed = { NativeBrowserTabs.shared.rename(tab: $0, to: $1) }
            // Their `localhost:<port>` pages, forwarded to the Mac when it serves `localhost`.
            NativeBrowserTabs.shared.forwarder = StreamedBrowserDirectory.shared.localhost
            NativeBrowserTabs.shared.macForwardsLocalhost = { [store] macID in
                macID.flatMap { store.macCapabilities[$0] }?.contains(NativeBrowserTabs.forwardCapability) ?? false
            }
        } else {
            StreamedBrowserDirectory.shared.opener = nil
            StreamedBrowserDirectory.shared.macOpener = nil
            FeedRouting.shared.clearAllNotifications = nil
            FeedRouting.shared.markAllNotificationsRead = nil
            FeedRouting.shared.replyToTerminal = nil
            terminalTabs.reconnect = nil
            terminalTabs.sessionProvider = nil
            terminalTabs.showConnectedDevices = nil
            terminalTabs.hasLiveSession = nil
            terminalTabs.artifactSourceProvider = nil
            terminalTabs.uploaderProvider = nil
            terminalTabs.screenTextProvider = nil
            creator.backend = offlineCreation
        }
    }

    /// Tells the coordinator which Macs' data is on screen: one workspace's
    /// Mac inside it, every Mac on the Workspaces list and the Feed, none on
    /// Home and Settings (their links close after `MacLinkPolicy.idleAfter`).
    func updateShownMacs() {
        if cloudChats != nil {
            // The Cloud sheet may be opened while Workspaces or the Feed has
            // links to other Macs. Keep the full directory shown while the
            // sheet is up; narrowing this to the selected Cloud Mac makes the
            // link policy evict the other Macs from its bounded set.
            live?.showing(macIDs: nil)
            return
        }
        guard let live else { return }
        switch tab {
        case .workspaces:
            if let shown = workspacesPath.last {
                live.showing(macIDs: [shown.macID])
            } else {
                live.showing(macIDs: nil)
            }
        case .feed:
            live.showing(macIDs: nil)
        case .home, .settings:
            live.showing(macIDs: [])
        }
    }

    /// A Mac left the account: a workspace page of it (and anything pushed
    /// on top) closes, back to the list.
    func macRemoved(_ macID: String) {
        if let index = workspacesPath.firstIndex(where: { $0.macID == macID }) {
            workspacesPath.removeSubrange(index...)
        }
    }

    /// Opens a tapped notification: Chief's reply on Home, an agent's event in
    /// its chat. Returns false while the tab is not known yet (the Mac's tree
    /// has not arrived), so the shell tries again when it does.
    @discardableResult
    func open(_ route: NotificationRoute) -> Bool {
        openRoute(route) // ShellModel+NotificationRoute.swift
    }

    /// Whether the route's chat is on screen now (its notification shows no banner).
    func isShowing(_ route: NotificationRoute) -> Bool {
        // Chief lives on Home: its conversation on screen there shows the message itself.
        if route.kind == "chief" {
            guard UIApplication.shared.applicationState == .active, tab == .home, let id = route.conversationID else { return false }
            return ChiefSession.conversationOnScreen == id
        }
        guard UIApplication.shared.applicationState == .active, tab == .feed, let shown = feedPath.last,
              let destination = live?.destination(sessionID: route.sessionID, workspaceID: route.workspaceID, tabID: route.tabID, macID: route.mac) else { return false }
        return destination == shown
    }

    /// The Mac refused a new workspace: its row is already gone; leave its
    /// screen if it is open, and say so.
    private func workspaceCreationFailed(_ placeholder: Workspace, message: String) {
        if let index = workspacesPath.firstIndex(where: { $0.id == placeholder.id }) {
            workspacesPath.removeSubrange(index...)
        }
        let mac = store.teams.flatMap(\.macs).first { $0.id == placeholder.macID }?.name ?? "the Mac"
        toast = CmuxMobileToast(symbol: "exclamationmark.circle", text: "Couldn't create a workspace on \(mac)")
        theme.haptics.error()
        shellLog.error("new workspace on \(mac, privacy: .public) refused: \(message, privacy: .public)")
    }

    // MARK: Last location (design/terminal P10)

    /// Where the user is now: the root tab, and on Workspaces the open
    /// workspace and its tab on screen.
    var lastOpenLocation: LastOpenLocation {
        guard tab == .workspaces, let shown = workspacesPath.last else { return LastOpenLocation(rootTab: tab.rawValue) }
        let id = store.resolvedWorkspaceID(shown.id)
        return LastOpenLocation(rootTab: tab.rawValue, workspaceID: id, macID: shown.macID, tabID: store.lastTabByWorkspace[id])
    }

    /// At launch: go back to the saved workspace and tab, now or once its
    /// Mac lists it (`continueRestore`).
    func beginRestore() {
        guard !restoreAttempted else { return }
        restoreAttempted = true
        guard pendingRestore == nil, let saved = lastOpen.load() else { return }
        pendingRestore = saved
        continueRestore()
    }

    /// A link opened: the launch restore is dropped.
    func cancelRestore() {
        restoreAttempted = true
        pendingRestore = nil
    }

    /// The workspaces (or a Mac's data phase) changed while a restore waits.
    func continueRestore() {
        if let macID = restoreLinkMac, let live,
           store.teams.flatMap(\.macs).contains(where: { $0.id == macID && $0.isOnline }) {
            restoreLinkMac = nil
            live.select(macID: macID)
        }
        guard let saved = pendingRestore else { return }
        let decision = LastOpenRestore.decide(saved: saved, workspaces: store.activeWorkspaces) { [store] in store.macDataPhase($0) }
        switch decision {
        case .nothing:
            pendingRestore = nil
        case .wait:
            if tab != .workspaces { tab = .workspaces }
        case .showList:
            pendingRestore = nil
            tab = .workspaces
        case .open(let workspaceID, let tabID):
            pendingRestore = nil
            guard let workspace = store.workspace(id: workspaceID) else { return }
            // The saved tab, never the Needs-you jump to a waiting agent
            // (that is for a user's tap, `WorkspacesList.openWorkspace`).
            if let tabID { store.noteOpened(tabID: tabID, in: workspaceID) }
            tab = .workspaces
            workspacesPath = [workspace]
            // Its tabs come from its Mac: link it, as a tap on the row does.
            if let live, store.teams.flatMap(\.macs).contains(where: { $0.id == workspace.macID && $0.isOnline }) {
                live.select(macID: workspace.macID)
            } else {
                // Not online yet at launch: link it as soon as it is.
                restoreLinkMac = workspace.macID
            }
            shellLog.info("restored workspace \(workspaceID, privacy: .public) tab \(tabID ?? "-", privacy: .public)")
        }
    }

    /// The location changed: remember it. A move by the user while a
    /// restore waits cancels the restore; the restore's own switch to the
    /// Workspaces list does not overwrite the saved workspace.
    func locationChanged(_ location: LastOpenLocation) {
        if pendingRestore != nil {
            if location == LastOpenLocation(rootTab: LastOpenLocation.workspacesTab) { return }
            pendingRestore = nil
        }
        // The user left the restored workspace: no late link for it.
        if let macID = restoreLinkMac, location.macID != macID { restoreLinkMac = nil }
        lastOpen.save(location)
    }

    /// How many screens are pushed on `tab`'s stack.
    private func depth(of tab: RootTab) -> Int {
        switch tab {
        case .home: homePath.count
        case .workspaces: workspacesPath.count
        case .feed: feedPath.count
        case .settings: settingsPath.count
        }
    }

    /// Whether the root tab bar shows while `tab` is selected: the only place
    /// that decides it (`ShellTabs` applies it to each tab). A screen pushed on
    /// Home, Workspaces or the Feed (a workspace and its pages, a chat, a
    /// conversation) owns the bottom edge (SPEC 3.1), so the bar hides while
    /// that stack is not at its root; Settings pages keep it.
    ///
    /// Pushed screens never hide it themselves: SwiftUI applied a pushed
    /// screen's `.toolbar(.hidden, for: .tabBar)` only when it was pushed on
    /// the tab already on screen, so a workspace opened from another tab in
    /// one update (a link, a notification, the Feed, the launch restore)
    /// showed over the bar, and a screen that hid it in some branches only
    /// (a conversation still loading) showed it in the others.
    func showsTabBar(on tab: RootTab) -> Bool {
        tab == .settings || depth(of: tab) == 0
    }

    /// The drawer pan only opens from a tab root (stack depth 1).
    private func updateInteractiveOpen() {
        sidebar.allowsInteractiveOpen = depth(of: tab) == 0
    }

    /// A team switch (a tap or a follow): screens that show the old team's Macs close (an
    /// open workspace and a chat opened from the Feed); Home and Settings stay.
    func closeTeamScreens() {
        workspacesPath.removeAll()
        feedPath.removeAll()
    }

    /// Row tap: selection haptic, highlight moves, drawer closes, content
    /// crossfades to the new team (SPEC 3.3 "Team switch").
    func switchTeam(to id: String) {
        guard id != store.activeTeamID else {
            sidebar.close()
            return
        }
        theme.haptics.selection()
        sidebar.crossfadeContent()
        withAnimation(theme.motion.snap.animation) {
            store.selectTeam(id)
        }
        closeTeamScreens()
        sidebar.close()
        live?.activeTeamChanged(byUser: true)
        guard !id.hasPrefix("personal-") else { return }
        Task { await auth.selectTeam(id) }
    }

    /// The banner over Workspaces: no network first, then the live link (SPEC 7.4).
    var banner: ConnectionBannerState? {
        #if DEBUG
        // Layout captures only: `-cmux-mobile-banner-demo pairing|pairing-reset|reconnecting`.
        switch UserDefaults.standard.string(forKey: "cmux-mobile-banner-demo") {
        case "connected"?: return .connected
        case "reconnecting"?: return .reconnecting(to: "Mac Studio")
        case "offline"?: return .connectionFailed
        case "pairing"?: return .waitingForPairing(on: "Mac Studio")
        case "pairing-reset"?: return .waitingForPairingAfterNewKeys(on: "Mac Studio")
        default: break
        }
        #endif
        if store.isOffline { return .offline }
        // Pairing (verify/phone-approvals.md): the Mac asks the user the first time.
        switch live?.pairingState {
        case .waiting(let mac)?: return .waitingForPairing(on: mac, identity: live?.focusedMacID)
        case .waitingAfterNewKeys(let mac)?: return .waitingForPairingAfterNewKeys(on: mac, identity: live?.focusedMacID)
        case .denied(let mac)?: return .failed("\(mac) did not allow this iPhone", identity: live?.focusedMacID)
        case .failed(let reason)?: return .failed("Pairing failed: \(reason)", identity: live?.focusedMacID)
        default: return live?.banner
        }
    }

    /// Saves a team's color and emoji (and `PUT /prefs` when live).
    func saveAppearance(_ appearance: TeamAppearance, for team: Team) {
        guard let live else {
            store.setAppearance(appearance, for: team.id)
            return
        }
        Task {
            do {
                try await live.saveAppearance(appearance, teamID: team.id)
            } catch {
                toast = CmuxMobileToast(symbol: "exclamationmark.circle", text: "Saved on this iPhone only")
            }
        }
    }

    /// Live mode: `POST /v1/teams/:id/invites {email}` (Stack emails the invitation).
    func sendInvite(email: String, to team: Team) {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let live, !address.isEmpty else { return }
        isFetchingInvite = true
        Task {
            defer { isFetchingInvite = false }
            do {
                try await live.invite(email: address, teamID: team.id)
                toast = CmuxMobileToast(symbol: "envelope", text: "Invitation sent to \(address)")
                theme.haptics.success()
            } catch {
                toast = CmuxMobileToast(symbol: "exclamationmark.circle", text: "Couldn't send the invitation")
                theme.haptics.error()
            }
        }
    }

    /// Call Chief from anywhere: the live call, or Settings → Chief Calls
    /// when this account has no OpenAI API key yet.
    func callChief() {
        guard !ChiefLiveCall.shared.start() else { return }
        openChiefCallSettings()
    }

    /// Sends Send Message…'s message to the Chief of the workspace's Mac (Chief follows the
    /// focused Mac, as a Chief notification moves it), then shows that conversation on Home.
    func sendToChief(_ text: String, about subject: ChiefMessageAbout) {
        if let live, live.canLink(macID: subject.macID), live.focusedMacID != subject.macID { live.select(macID: subject.macID) }
        ChiefSources.shared.mac.send(text: text)
        messagingChief = nil
        tab = .home
        homePath = NavigationPath(chiefConversation: nil)
    }

    func openChiefCallSettings() {
        tab = .settings
        settingsPath = [.chiefCalls]
    }

    func invite(to team: Team) {
        if live != nil {
            if team.id.hasPrefix("personal-") {
                toast = CmuxMobileToast(symbol: "person.2", text: "Create a team to invite people")
            } else {
                invitingTeam = team
            }
            return
        }
        guard !isFetchingInvite else { return }
        isFetchingInvite = true
        Task {
            defer { isFetchingInvite = false }
            do {
                let url = try await auth.inviteLink(teamID: team.id)
                shareURL = ShareItem(url: url)
            } catch CmuxMobileAuthModel.InviteError.serviceUnavailable {
                toast = CmuxMobileToast(symbol: "link", text: "Invite links need the cmux service")
            } catch {
                toast = CmuxMobileToast(symbol: "exclamationmark.circle", text: "Couldn't create an invite link")
                theme.haptics.error()
            }
        }
    }

    func createTeam(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                let team = try await auth.createTeam(named: trimmed)
                var teams = store.teams.map { AppStore.AccountTeam(id: $0.id, name: $0.name) }
                if !teams.contains(where: { $0.id == team.id }) { teams.append(team) }
                if let live {
                    live.applyAccountTeams(teams.filter { !$0.id.hasPrefix("personal-") }, selectedID: team.id)
                } else {
                    store.applyAccountTeams(teams, selectedID: store.activeTeamID)
                }
                theme.haptics.success()
                switchTeam(to: team.id)
            } catch ServiceTeamCreation.Failure.unavailable {
                toast = CmuxMobileToast(symbol: "exclamationmark.circle", text: "Your account can't create teams")
                theme.haptics.error()
            } catch {
                toast = CmuxMobileToast(symbol: "exclamationmark.circle", text: "Couldn't create the team")
                theme.haptics.error()
            }
        }
    }

    func joinTeam(inviteLink: String) {
        Task {
            do {
                try await auth.joinTeam(inviteLink: inviteLink)
                toast = CmuxMobileToast(symbol: "checkmark", text: "Joined the team")
                theme.haptics.success()
            } catch {
                toast = CmuxMobileToast(symbol: "exclamationmark.circle", text: "That invite link didn't work")
                theme.haptics.error()
            }
        }
    }
}

/// `UIActivityViewController` for invite links.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
extension ShellModel {
    /// Signed in: one Screen Sharing service for the account (it opens the
    /// device hub when its page first shows). Signed out: it ends and forgets the hub.
    func attachScreenSharing(signedIn: Bool) {
        guard signedIn else {
            screenSharing?.stop()
            screenSharing = nil
            ScreenSharingService.current = nil
            return
        }
        guard screenSharing == nil else { return }
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let auth = auth
        let configuration = ScreenSharingService.Configuration(
            baseURL: ScreenSharingService.hubURL(isDebug: isDebug, environment: ProcessInfo.processInfo.environment),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.cmux.mobile",
            deviceName: UIDevice.current.name,
            tokens: DeviceHubAccountToken { try await auth.accessToken() }
        )
        let service = ScreenSharingService(configuration: configuration)
        screenSharing = service
        ScreenSharingService.current = service
    }
}
#endif
