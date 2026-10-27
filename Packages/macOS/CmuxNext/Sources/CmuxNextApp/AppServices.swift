import AppKit
import CmuxNextActions
import CmuxNextApps
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextBrowserHistory
import CmuxNextChiefPetWiring
import CmuxNextChromiumWarmup
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDesign
import CmuxNextMobileHost
import CmuxNextNowPlaying
import CmuxNextDaemon
import CmuxNextEnergy
import CmuxNextFeatures
import CmuxNextFeed
import CmuxNextFavicons
import CmuxNextHibernation
import CmuxNextHomeEngine
import CmuxNextIcons
import CmuxNextInput
import CmuxNextKeepAwake
import CmuxNextLayout
import CmuxNextLaunch
import CmuxNextMemory
import CmuxNextPalette
import CmuxNextPages
import CmuxNextPopups
import CmuxNextRemoteLocalhostService
import CmuxNextBrowserImport
import CmuxNextPhone
import CmuxNextPhoneAccess
import CmuxNextServer
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextSignposts
import CmuxNextTerminal
import CmuxNextTrace
import CmuxNextUpdater
import CmuxNextVSCodeServer
import CmuxNextWakeups
import CmuxNextWorkspaceNaming
import CmuxNextWorkspaceRepair
import os
import WebKit
import CmuxNextFocusUI
import CmuxNextTabs
/// Process-wide services the window controllers share. Model state is not
/// here: the daemon owns it, windows own their local state.
final class AppServices {
    /// The app's theme store (the one ``ThemeScope/app`` roots on), handed to the App's theme owners.
    let themeStore = ThemeScope.app.store
    /// The recovery-draft backstop of unsaved documents (R96).
    let recoveryDrafts = RecoveryDraftStore(directory: RecoveryDraftFiles.defaultDirectory)
    /// The quit hook's unsaved-document participants; drafts go to ``recoveryDrafts``.
    private(set) lazy var quitUnsaved = QuitUnsavedRegistry(drafts: recoveryDrafts)
    /// The open files' quit documents, shared by the markdown and editor pages.
    private(set) lazy var fileQuitDocuments = FileQuitDocuments(drafts: recoveryDrafts, registry: quitUnsaved)
    let environment: AppEnvironment; let agentPaneEnvironment: [String: String]?
    /// Each window's last sidebar, drawn before the daemon answers.
    let sidebarSnapshots: SidebarSnapshotStore
    /// Launch load-in by region; tests inject one with their own clock.
    let launchReveal: LaunchReveal
    /// Run marker, restart notice, crash reports (`debug.crashes`).
    let crashRecovery: CrashRecoveryService
    /// Crash and exception reports to Sentry (cx-urd.58); started only for the app process.
    let crashReporting: AppCrashReporting
    /// The local daemon (a build with the sidebar document orders rows from it only: placement-shift-v1). Cloud machines
    /// are in `machines`; code acting on a workspace, pane, or tab resolves its daemon through `machines`.
    /// Its event batches run on the app's ``MainWorkScheduler`` (``mainWork``), which every
    /// remote machine's service shares.
    let daemon: DaemonService
    /// The app's one main-thread scheduler (from the composition root), passed by init to the
    /// local daemon and to the Cloud, SSH and server services for their machines.
    let mainWork: MainWorkScheduler
    private(set) lazy var mainDeadlines = MainDeadlineScheduler(work: mainWork)  // the app's one `MainDeadline` placer
    /// The local and peer chat upload stagers' expiry deadlines.
    private(set) lazy var chatUploadExpiry = MainDeadline(owner: "AgentChatUploads.stageExpiry", workClass: .background, scheduler: mainDeadlines)
    private(set) lazy var peerUploadExpiry = MainDeadline(owner: "AgentPeerUploads.stageExpiry", workClass: .background, scheduler: mainDeadlines)
    /// Agent panes' git reads, one link per machine (AgentPaneGitReads.swift).
    private(set) lazy var agentGit = AgentPaneGitLinks(machines: machines)
    let machines: MachineRegistry
    /// The names sidebar rows keep while their front tab's is briefly unknown (`WorkspaceAutoNameWiring`).
    let autoNameHold = WorkspaceAutoNameHold()
    /// The machine of the action being run, while its handler runs (`ActionRouting`); `activeDaemon` prefers it.
    var routedDaemon: DaemonService?
    /// Brings a window forward for a jump (`revealTab`, a `cmux://` link).
    /// Tests replace it to record the intent without ordering windows in.
    var showJumpWindow: @MainActor (NSWindow, WindowActivation.Intent) -> Void = { WindowActivation.show($0, $1) }
    /// The app's key window. Tests and `debug.key` replace it: a window only becomes key in a running, active app.
    var keyWindowSource: @MainActor () -> NSWindow? = { NSApp.keyWindow }
    /// Restart CLI Listener: binds the control socket again. Set once the
    /// app's control socket starts; nil while it has none (tests, socket off).
    var restartControlListener: (@MainActor () throws -> Void)?
    /// Agents' and scripts' Cloud machine creates waiting on the person in every window's sidebar card.
    let machineAsks = SidebarAsks()
    /// The account's sign-in, apart from ``cloud`` so its launch readers (the managed team, Home, a sign-in callback) build no
    /// CloudService. Its first token or restore reader starts the session restore (`CloudAuth.start`); a sign-in starts Cloud.
    private(set) lazy var cloudAuth: CloudAuth = CloudAuth(configuration: CloudConfiguration.current(isDebugBuild: ControlService.isDebugBuild))
    /// ``cloud`` and ``feed`` (AppServices+Cloud.swift), built at their first read: nil until then (no IUO).
    var cloudIfBuilt: CloudService?, feedIfBuilt: FeedService?
    /// The Cloud policy and the `feed.github` setting, applied when ``cloud`` and ``feed`` are built.
    var cloudPolicyDisabled = false, feedGitHub: (enabled: Bool, pollIntervalSeconds: Double)?
    var cloudContext: Task<Void, Never>?  // the Cloud start's registry context follow; nil until Cloud starts
    var cloudStart: CloudStartPost?  // the launch's Cloud start (`postCloudStart`); nil in tests
    var showcase = ShowcaseState()
    /// The wide Inbox page, backed by `feed.model`.
    private(set) lazy var feedPage = FeedPageService(services: self)
    /// SSH machines (Connect to Machine…); `serverReach`: paired servers' Chief sessions in the sidebar.
    var ssh: SSHService { madeSSH ?? SSHService.made(for: self) }  // on first use, never in init (p08-startup-021)
    var madeSSH: SSHService?
    private(set) lazy var serverReach = ServerReachService.app(services: self)
    /// Add Machine and Check Machine (plans/cmux-next/add-machine-DESIGN.md); each machine's last check.
    private(set) lazy var addMachine = AddMachineCard(services: .app(self))
    /// Add Device and Settings > Devices (plans/cmux-next/add-device-DESIGN.md): one entry, one list, one remove.
    private(set) lazy var addDevice = AddDeviceCard(services: .app(self), mainWork: mainWork)
    private(set) lazy var devices = DeviceDirectory.app(self)
    let machineHealth = MachineHealthStore()
    /// Layout passes and tree changes of off-screen workspaces, all windows (`debug.layout_counters`).
    let hiddenLayoutWork = HiddenLayoutWork()
    /// The app's one fan-out of app-wide notices (`AppEvents`, p06-scheduler-021): every window's
    /// key tracker and later adopters subscribe here, one observer per name for the whole app.
    let appEvents = AppEvents(center: .default)
    /// The app's one fan-out of `NSWorkspace.shared.notificationCenter` notices; ``appearance``
    /// observes the display options through it (`observeGlass`) and ``appVisibility`` the display sleeps.
    // raw-observer-allow: the AppEvents fan-out itself, one observer per workspace notice for the whole app
    let workspaceEvents = AppEvents(center: NSWorkspace.shared.notificationCenter)
    /// The app's node in the visibility tree (hidden app, sleeping displays), every window's
    /// node's parent (`WindowVisibilitySource`, p06-scheduler-022).
    private(set) lazy var appVisibility = AppVisibilitySource(
        appEvents: appEvents, workspaceEvents: workspaceEvents,
        isAppHidden: NSApp.isHidden
    )
    /// Reduce Motion, the motion switches, hover cards, the inactive dim and the system's display
    /// options (``AppearanceSignals``, p06-scheduler-043), handed to the readers this root builds:
    /// the glass watch, every window and the content its panes show. The design settings own it,
    /// so `Motion` reads the same one.
    let appearance: AppearanceSignals
    let mobile: MobileHostService  // phone access; the account layer starts it
    /// iPhone connections for the cmux-next iPhone app (cmux-next-ios, Settings > Mobile).
    let iphone = IPhoneHostService()
    /// Every action run's perform-to-commit time against the 10 ms budget (always on; zero-latency.md),
    /// each run published on the board of the app's ``MainWorkScheduler`` so the watchdog samples a slow one.
    let actionBudget: ActionBudgetMonitor
    /// `motion.late_commits`: the main commits that miss their frame while a Motion animation runs (starts no link).
    let motionLateCommits = MotionLateCommits(displays: FrameScheduler.appDisplays)
    /// Every action; timed by the always-on `action.*` signposts and `actionBudget`, in Debug and Release.
    let registry: ActionRegistry
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The refactor oracle's turn checkpoints (`debug.oracle.turns`): the registry's perform-turn observer.
    /// Release builds have none, and their registry has no observer.
    let oracleTurns = OracleActionTurns()
    #endif
    /// The main-thread blocking detector's handle (threading-model.md): the Debug menu, `debug.blocking` and the hang report sink (``BlockingReportSink``).
    let blocking = BlockingDetector.forProcess()
    /// The local daemon's wire counters (`debug.daemon.wire`); nil in a release build.
    let wireStats: DaemonWireStats?
    /// The observers' per-owner counts (`debug.observations`): each observer kind interns its owner here when it is
    /// built. It is the main-thread scheduler's one ledger, so every `VisibleObservation` records into it too.
    var observations: ObservationLedger { mainWork.observations }
    /// Sparkle updates (release builds) or read-only feed probes (DEV).
    let updater: UpdaterService
    /// The app's one file picker made ahead of the click (agent panes, page inputs, Home's "+") and agent page WebKit warm-up.
    let openPanel = MadeAheadOpenPanel(), agentPageWarmup = AgentPageWarmup(chromiumChat: { AgentPaneTunables.chromium.value })
    /// "Restart cmux-tui to use new features" (plans/cmux-next/server-updates-DESIGN.md).
    private(set) lazy var serverUpdates = ServerUpdatePresenter(daemon: daemon, defaults: .standard,
                                                                 activeWindow: { [weak self] in self?.windows.active?.window })
    private(set) lazy var updateSheet: UpdateSheetController = UpdateSheetController(source: UpdateSheetModel(service: updater, openLink: { LinkRouter.shared.open($0) }))  // first read in init (no IUO)
    /// cmux.json controller; set by `AppDelegate` once it starts. Agent tabs made before it (by launch's action bindings) follow it from here.
    var settings: SettingsController? { didSet { if let settings, settings !== oldValue { madeAgentTabs?.follow(settings); browserHost?.follow(settings); madeRemoteLocalhost?.follow(settings); if cloudContext != nil { followHostReplica(settings) } } } }
    /// Writes the palette shortcut recorder's edits (the recorder holds it weakly).
    var paletteShortcutEditor: PaletteShortcutEditor? {
        didSet { palettes.built?.shortcutRecorder.editor = paletteShortcutEditor }
    }
    /// Where Chromium comes from: embedded, or downloaded on first use (bundle-size-DESIGN.md section 6).
    let chromiumRuntime: ChromiumRuntimeService
    /// The browser stores both engines and the App share: the one answer to "is this profile off the record".
    let browserStores = BrowserSharedStores.application()
    /// Chromium sign-in tabs: the engine's runtime and the sign-in windows share it.
    let signInCallbacks = CEFSignInCallbacks()
    /// Every terminal's grid sender: next frame, one in flight, a split's or close's final grid at once.
    let resizes = ResizeCoordinator()
    private(set) lazy var cache: TabContentCache = TabContentCache(daemon: daemon, chromium: makeChromiumSlot(), fileInput: openPanel, resizes: resizes, terminalModifiers: TerminalModifierWatch(input: inputTap), terminalPointerFrames: terminalPointerFrames, mainWork: mainWork, imageCaches: ImageCacheShares(.forThisMac(gpuResidentAvailable: false), budgeted: features.isEnabled(.memoryImageCaches)), gpuResidency: features.isEnabled(.terminalGPURelease) ? GhosttyGPUResidency() : nil)  // first read in init (no IUO); its Chromium engine at its first read
    /// What the Now Playing card shows and drives: the player while it plays, else the playing tab,
    /// else another app that plays (Spotify, Music: macOS Now Playing, cmux's own entries left out)
    /// while `sidebar.nowPlaying.otherApps` is on (off by default: only what plays in cmux). Its
    /// macOS Now Playing adapter stops a minute after the last surface on ``mainDeadlines``.
    private(set) lazy var nowPlayingSources = NowPlayingSources(
        player: cache.pageRequests.music, tabs: cache.pageRequests.sidebarNowPlaying,
        system: SystemNowPlaying.bundled(deadlines: mainDeadlines),
        otherApps: { [weak self] in self?.settings?.snapshot.nowPlaying.otherApps ?? NowPlayingSettings.otherAppsDefault })
    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.terminal_final_grid`: a split's or close's terminal grids, sent, drawn and announced.
    private(set) lazy var finalGridTrace: TerminalFinalGridTrace = {
        let trace = TerminalFinalGridTrace { [weak self] in self?.cache.terminals.map { ($0.key, $0.value.session, ObjectIdentifier($0.value.io)) } ?? [] }
        resizes.onSend = { [weak trace] in trace?.noteSend($0, columns: $1.cols, rows: $1.rows) }
        return trace
    }()
    #endif
    let switchHits = SwitchHits(counting: ControlRouter.debugMethodsAllowed) // refactor-switch sites' arm counts (debug.oracle.switch_hits)
    private(set) lazy var windows: WindowManager = WindowManager(services: self)  // first read in init (no IUO)
    private(set) lazy var dragSession: TabDragSession = TabDragSession(services: self)  // built by the first drag
    /// The command palette on demand (p08-startup-023): launch builds none; it is built after the first frame
    /// (`postBuild`) or by the first palette key, in that key's turn. Handlers add pages to `palettes.sources`.
    private(set) lazy var palettes = PaletteOnDemand(registry: registry, sources: { [weak self] in self.map { PaletteSourcesBridge.make(services: $0) } ?? PaletteSources() }) { [registry, mainWork, weak self] sources in
        PaletteController(registry: registry, sources: sources, usage: self.map { DaemonPaletteUsageStore(services: $0) }, mainWork: mainWork, hoverFrameInput: self?.hoverFrameInput)
    }
    var palette: PaletteController { palettes.controller }
    private(set) lazy var previews: TabPreviewSource = TabPreviewSource(cache: cache)  // built by the first tab card
    /// CPU and memory for the hover cards and `resources` (sampled on demand).
    private(set) lazy var resources: AppResourceSource = AppResourceSource(services: self)  // built by its first reader
    private(set) lazy var presentation = ContentPresentationScheduler(mainWork: mainWork)
    private(set) lazy var newTabCloseFrames = FrameBatcher(owner: "NewTabPage.close", scheduler: mainWork.frames)  // a pick's page close: unbudgeted
    /// Blank-pane invariant, checked after each presentation settle.
    let surfaceInvariant = SurfaceInvariantMonitor()
    /// Input invariants, desync reports, focus journaling and the no-activate keyboard guard.
    let input = InputVerificationService()
    /// Built by its first reader (a window's content, a tab close, a workspace create), else by its afterStartup
    /// post (`postNonPaintServices`), so a launch with no window still follows its workspaces.
    private(set) lazy var emptyWorkspaces: EmptyWorkspaceRepair = EmptyWorkspaceRepair(daemon: daemon)
    /// The closed-tab signal and the undo toasts of user closes; set when the tab handlers bind. The daemon owns the closed history (`DaemonClosedHistory`).
    var closedTabs: ClosedTabsFeed?
    lazy var findWorkGitHub: any GitHubFeedAPI = GitHubCLIClient(executable: AgentChatPullRequestReader.findGitHubCLI() ?? "/usr/bin/env")  // Find Work's `gh` reads; tests replace it
    private(set) lazy var pullRequests = AgentPullRequestReads()  // every pull request read with the user's `gh`: two at once, app-wide (cx-mb1e0)
    /// The app-wide "where was I" trail (plans/cmux-next/history.md 4.2).
    private(set) lazy var locationTrail = LocationTrailService(services: self)
    /// The terminals and agent chats focused last: what new ones copy (``WorkContextTrail``).
    var workContext = WorkContextTrail()
    /// The merged history read side and the per-profile visit logs.
    private(set) lazy var history = HistoryService(services: self)
    /// `cmux://history`: opens the page and serves its data.
    private(set) lazy var historyPage = HistoryPageService(services: self)
    /// The local model relay's bearer lease (Router/ModelRouterLease.swift); nil without acpmux.
    private(set) lazy var modelRouter: ModelRouterLease? = {
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        guard let acpmux = AcpmuxEnvironment.resolve(build: environment.build, bundledBinDirectory: bin,
                                                     environment: ProcessInfo.processInfo.environment) else { return nil }
        return ModelRouterLease(tokens: cloudAuth, apiBaseURL: FeedService.apiBaseURL(auth: cloudAuth), acpmuxHome: acpmux.home,
                                logger: Logger(subsystem: "com.cmuxterm.app.next", category: "model-router"))
    }()
    /// Where agent cursors draw (plans/cmux-next/agent-cursor.md section 3).
    private(set) lazy var agentCursorVisibility = AgentCursorWiring.makeVisibility(services: self)
    /// What agent cursor tags say and where a click on one goes.
    private(set) lazy var agentCursorTagLinks = AgentCursorTagLinks { [weak self] tab in
        self?.revealTab(tab, intent: .raise) ?? false
    }
    /// The session vault (past agent sessions); tests may set one over a fixed source.
    lazy var vault: SessionVault = SessionVault(source: AgentHistorySource(services: self))
    /// `cmux://vault`: Open Vault as Pane.
    private(set) lazy var vaultPages: VaultPageService = VaultPageService(vault: vault, registry: registry)
    /// Where each window's right sidebar remembers its state (tests set a suite of their own).
    var rightSidebarDefaults: UserDefaults = .standard
    /// Each window's file explorer (the right sidebar's Files section) and its actions' effects.
    private(set) lazy var fileExplorers = FileExplorerService(services: self)
    /// The right sidebar's sections by mode (the file explorer adds Files and Find): built by the first panel, or by
    /// the afterStartup post of its icon build (`postLaterTabWarmups`).
    private(set) lazy var rightSidebarSections: RightSidebarSections = {
        let sections = RightSidebarSections(startup: launchStartup)
        sections.registerAppSections()
        return sections
    }()
    /// `cmux://agent-activity`: the computer use sessions page.
    private(set) lazy var agentActivityPage = AgentActivityPageService(services: self)
    /// `cmux://screenshots`: the Screenshots pane (its detection, thumbnail cache and pages).
    private(set) lazy var screenshotsPage = ScreenshotsPageService(services: self)
    private(set) lazy var remoteViewPages = RemoteViewPageService()
    /// Mac Screen: paired Macs' screens and Share This Mac.
    private(set) lazy var macScreenPages = AppServices.makeMacScreenPages(self)
    /// Mac Screen page tabs (`InternalPageID.macScreen`).
    private(set) lazy var macScreenTabs = MacScreenPageService(services: self)
    /// The device hub (built in; `deviceHub.url` overrides it in DEV builds): the user's devices for Mac Screen and Settings > Devices.
    private(set) lazy var deviceHub = AppServices.makeDeviceHub(self)
    /// Bookmarks of every browser profile (plans/cmux-next/bookmarks.md).
    private(set) lazy var bookmarks = BookmarkService(services: self)
    /// The user's keybindings.json, owned by the home daemon, as the binding table's user layer.
    private(set) lazy var keybindingsFile = KeybindingsFileService(services: self)
    /// App platform (DEV prototype): registry, JavaScriptCore app host, App Store.
    private(set) lazy var apps = AppsService(services: self)
    private(set) lazy var sidebarCustomization = SidebarCustomizationService(client: apps.client) { [weak self] in self?.apps.presence.isPresented($0) == true }
    /// The Tasks page and its mirror of the local Tasks owner (plans/cmux-next/tasks.md).
    private(set) lazy var tasks = TasksPageService(services: self)
    /// Phone tabs: iOS simulators, Android emulators and real phones, recordings, feedback to Chief
    /// (plans/cmux-next/phone.md, simulators-DESIGN.md).
    private(set) lazy var phones: PhoneService = {
        let folder = SidebarSnapshotFile.buildDirectory(launch: environment.launch).appending(path: "phone", directoryHint: .isDirectory)
        // One SimulatorKit host serves the iOS backend's input and the phone tabs' live screens.
        let simulatorKit = SimulatorKitHID(developerDirectory: SimulatorKitHID.selectedDeveloperDirectory())
        let backend = PlatformPhoneBackend(ios: XcodePhoneBackend(hid: simulatorKit),
                                           android: AndroidSDK.locate().map { AndroidPhoneBackend(sdk: $0) })
        return PhoneService(backend: backend, recordings: folder.appending(path: "recordings", directoryHint: .isDirectory),
                            scratch: FileManager.default.temporaryDirectory.appending(path: "cmux-phone", directoryHint: .isDirectory),
                            live: simulatorKit)
    }()
    private(set) lazy var phoneFeedback = PhoneChiefFeedback(home: home)
    /// Every declared feature's value (`schemas/features/features.d`, Chrome's `base::FeatureList`):
    /// resolved once in init (crash reporting reads it first) from this build's channel and the launch environment
    /// (`CMUX_ENABLE_FEATURES`, `CMUX_DISABLE_FEATURES`). Tests set their own before the services that read it are built.
    var features: FeatureList
    /// The windows' frame-aligned pointer input (p04-input-030), one coalescer per window shared by every consumer, as
    /// Chromium has one input queue per frame widget. It is the application's own `frameInput`, the one `sendEvent`
    /// flushes before discrete input (a test's app has none: its own). Read only while a feature below uses it.
    private lazy var pointerFrames: FrameInputCoalescers = (NSApp as? CmuxApplication)?.frameInput ?? FrameInputCoalescers()
    /// Resize drags (feature `pointerFrameDrags`): pane dividers, column and row edges, both sidebars' resize edges
    /// and the DevTools divider move on a frame interval's first drag event and once more at its frame. Nil while it
    /// is off: each drag event moves them.
    private(set) lazy var dragFrameInput: FrameInputCoalescers? = features.isEnabled(.pointerFrameDrags) ? pointerFrames : nil
    /// Hover (feature `pointerFrameHover`, also each main window's `hoverFrameInput`): hover sites, the palette, the
    /// omnibox suggestions and the pages' popups act on a frame interval's first move and once more at its frame, at
    /// the latest point. Nil while it is off: each move hovers.
    private(set) lazy var hoverFrameInput: FrameInputCoalescers? = features.isEnabled(.pointerFrameHover) ? pointerFrames : nil
    /// Terminals (feature `terminalPointerFrames`, p04-input-034): moves, drags and mouse-reporting trackpad scrolls
    /// reach Ghostty on a frame interval's first event and once more at its frame. Nil while it is off: each event
    /// reaches Ghostty at once.
    private(set) lazy var terminalPointerFrames: FrameInputCoalescers? = features.isEnabled(.terminalPointerFrames) ? pointerFrames : nil
    /// Remote panes (feature `pointerFrameRemoteInput`): remote desktop and remote browser tabs send moves, drags and
    /// mid-gesture scrolls to the host on a frame interval's first event and once more at its frame (p04-input-035).
    /// Nil while it is off: each event goes to the host at once.
    private(set) lazy var remotePointerFrames: FrameInputCoalescers? =
        features.isEnabled(.pointerFrameRemoteInput) ? pointerFrames : nil
    /// The Task Manager page and Kill Process (`TaskManagerPageService`).
    private(set) lazy var taskManager = TaskManagerPageService(services: self)
    /// The Todo page: a workspace's checklist (`workspace-checklist-v1`).
    private(set) lazy var workspaceTodo = WorkspaceTodoPageService(services: self)
    /// The viewers' recents, the cmux picker, the diff, markdown and editor tabs (R89, S4, S6, S7).
    private(set) lazy var viewers = ViewerService(services: self)
    /// Where a link or path the person opens lands (`layout.linkPlacement`): beside its pane.
    private(set) lazy var linkOpener = LinkOpener(services: self)
    /// A link dragged out of a chat into a pane drop zone (``LinkDragSession``).
    private(set) lazy var linkDrags = LinkDragSession(services: self)
    /// The cmux server menu bar item (DEV and NIGHTLY prototype; plans/cmux-next/server.md 14).
    private(set) lazy var serverMenuBar = ServerMenuBarController.app(services: self)
    /// Home: local conversations with the mux (plans/cmux-next/home.md).
    private(set) lazy var home = HomeService(services: self)
    /// `cmux://bookmarks`: the manager pages.
    private(set) lazy var bookmarkPages = BookmarkPageService(services: self)
    /// The sidebar section layout every window draws (plans/cmux-next/sidebar-sections.md); tests may set a fake owner.
    lazy var sidebarLayout: SidebarLayoutService = {
        let service = SidebarLayoutService(remote: DaemonSidebarLayoutRemote(services: self),
                                           onRefused: { [weak self] message in self?.registry.refuse(message) })
        service.start()
        SidebarDocWiring.start(self, layout: service)
        return service
    }()
    /// Sleepy Mode, the keep-awake screensaver (`palette.sleepyMode`); tests set one with fake seams.
    lazy var sleepyMode = SleepyModeController(
        keepAwake: SleepyKeepAwakeActivity(),
        overlay: SleepyOverlayWindows(workingAgents: { [weak self] in self?.workingAgentTabCount() ?? 0 },
                                      lockMac: { SleepyMacLock().lock() })
    )
    /// Native input for `browser.page.mouse|wheel|insert_text|key` (`BrowserNativeInputs`).
    let browserNativeInputs = BrowserNativeInputs()
    /// Each pane's own Hide Tab Bar choice (`PaneTabBarChoices`).
    let paneTabBars = PaneTabBarChoices()
    /// The panes in Full Width Tab mode (`PaneFullWidthTabs`).
    let paneFullWidthTabs = PaneFullWidthTabs()
    /// Pane controller mounts and releases in any window (`PaneMounts`).
    let paneMounts = PaneMounts()
    /// The new tab screen's Search | Ask mode and last agent, and what `!` typed ahead.
    let newTabChoices = NewTabChoiceMemory()
    /// The New Tab weather widget's last reading and its refresh (`tabs.newTabWidgets.weather`).
    let newTabWeather = NewTabWeather()
    /// The models picked per harness in the Chief card's Model menu (its Recent section).
    let chiefModelRecents = HomeChiefModelRecents(defaults: .standard)
    let newTabTypeAhead = NewTabTypeAhead()
    /// Home's first-run Switching card: Hide memory and the Mission Control check.
    let homeSwitchKeys = HomeSwitchKeysSource()
    /// The app's one kernel memory pressure source, shared by every owner that reacts to pressure.
    let memoryPressure = MemoryPressureEvents(source: KernelMemoryPressureSource())
    /// The app's one memory coordinator (consumers register in AppServices+Memory.swift); it releases in background work.
    private(set) lazy var memoryCoordinator = AppMemoryConsumers.coordinator(pressure: memoryPressure, mainWork: mainWork)
    /// Every window's parked workspaces: torn down one per release slice at critical memory pressure, and
    /// held to the Mac's budget with `memoryDiscardParkedWorkspaces`.
    private(set) lazy var parkedWorkspaceBudget: ParkedWorkspaceBudget = makeParkedWorkspaceBudget()
    /// The app-wide list of hidden terminal frames (Chrome's FrameEvictionManager, p03-rendering-099):
    /// nil unless `memoryHiddenFrameLRU`.
    private(set) lazy var hiddenFrames: HiddenFrameLRU? = makeHiddenFrameLRU()
    /// The local memory histograms `debug.memory` shows (never uploaded); discards count per instrumented `ContentKind`.
    private(set) lazy var memoryHistograms = MemoryHistograms(pressure: memoryPressure, discardKinds: MemoryHistograms.hibernationKinds)
    /// Samples the footprints into `memoryHistograms` once an hour (startHibernationMeasurements starts it).
    private(set) lazy var memoryFootprints = MemoryFootprintEmitter(
        histograms: memoryHistograms, webContentPIDs: { [weak self] in if let self { AppMemoryModel.liveWebContentPIDs(self) } else { [] } },
        sample: { await AppMemoryModel.processes(webContentPIDs: $0) })
    /// The New Tab page on the app's one preload slot, which it installs on `webUI` (instant open, p13-webui-044).
    private(set) lazy var newTabSpares = NewTabPreload.app(self)
    /// The spare React page hosts for Settings, History and Cloud.
    private(set) lazy var pageHostPool = PageHostPool(memory: memoryCoordinator, policy: .init(preloadOnMakeVisible: features.isEnabled(.pageRendererAtFirstShow)),
                                                      hoverFrameInput: hoverFrameInput)
    /// The one owner of cmux pages (p13-webui.md 3.A): every page view opens and closes through it.
    /// Every page follows `browser.defaultEngine` (Chromium by default) through its one Chromium host.
    /// Its views are listed in `PageRegistry.processWide` while the static forwarders remain (p13-webui-010).
    private(set) lazy var webUI: WebUIHost = WebUIHost(
        chromium: ChromiumPageHost(
            chromium: cache.chromium,  // the engine at the first page opened in Chromium, not here
            preference: { [weak self] in
                self?.settings?.snapshot.browserDefaultEngine ?? self?.cache.browserTabs.preference.defaultEngine ?? .fallback
            },
            keyRouter: keyRouter, work: work),
        openPanel: openPanel, memory: memoryCoordinator, registry: .processWide, startsPagesAtFirstShow: features.isEnabled(.pageRendererAtFirstShow),
        hoverFrameInput: hoverFrameInput)
    /// The one icon picker (R94): Set Icon of workspaces, screens, spaces, browser profiles.
    private(set) lazy var iconPicker = IconPickerService(services: self, webUI: webUI)
    /// cmux.json command `actions`, registered as `cmuxConfig.<name>`.
    private(set) lazy var configActions: ConfigActionsController = ConfigActionsController(context: AppActionContext(services: self))  // built by its start
    /// System-wide hot keys for catalog actions marked `isGlobalHotKey`.
    private(set) lazy var globalHotKeys = GlobalHotKeyService.app(self)
    let terminalDelegate = TerminalHostDelegate()
    /// Attention rings, banners, sounds and dismissal (plans/cmux-next/notifications.md).
    let notifications = NotificationCenterService()
    /// Email verification AutoFill (`browser.verificationAutofill.enabled`, off by default): a code
    /// or link from Mail.app offered in the prompt bar of a page of the sender's own site
    /// (plans/cmux-next/email-verification-autofill/DESIGN.md). Built on the first page that waits,
    /// so the Public Suffix List is read only then. Turning the setting off withdraws offers at
    /// the next read (within `pollInterval`).
    private(set) lazy var verificationAutofill = VerificationAutofillCoordinator(
        inbox: VerificationInbox(policy: VerificationOfferPolicy(publicSuffixes: PublicSuffixList.bundled() ?? PublicSuffixList(listText: ""))),
        source: MailAppVerificationSource(),
        isEnabled: { [weak self] in self?.settings.map { BrowserVerificationAutofillSetting.current($0).enabled } ?? false }
    )
    /// Design mode in browser panes: highlights become cards in an agent chat
    /// (plans/cmux-next/design-mode-DESIGN.md).
    private(set) lazy var designMode = BrowserDesignModeController(services: self)
    private(set) lazy var uiInspector = UIInspectorController(services: self, tap: inputTap)
    /// The one keyboard router (plans/cmux-next/focus.md section 5).
    /// The input event being dispatched now (``InputDispatchContext``): `sendEvent` and the router's own dispatches.
    /// Each scroll event it dispatches is timed to its frame (`key.scroll_frame`), and each key-down or
    /// mouse-down is reported to ``mainWork`` (`noteDiscreteInput(expectsFrame:)`), and the span of its dispatch
    /// (`noteDiscreteDispatch(began:)`).
    let inputDispatch: InputDispatchContext
    let inputTap: InputEventTap  // the one input tap (AppDelegate's; a test's own); owners subscribe, never add event monitors (p04-input.md 3 (A))
    /// One input latency slot per tracked event (p04-input.md 3 (I)), its target by surface, most specific first;
    /// an agent chat's Chromium page window (`CefNSWindow`) is the agent pane's. Its key and scroll slots carry the
    /// `key.frame` and `key.scroll_frame` intervals.
    private(set) lazy var inputLatency = InputLatencyDispatch(
        tracker: InputLatencyTracker(presentation: PresentationClock()),
        classifier: InputTargetClassifier(rules: [
            .view(TerminalSurfaceView.self, is: .terminal), .view(AgentPaneView.self, is: .agentPane),
            .windowClassNamed("CefNSWindow", is: .chromiumPage, owner: { [weak self] page in
                self?.madeAgentTabs?.views.values.contains { $0.chromiumPage?.contentView.window === page } == true ? .agentPane : nil
            }),
            .view(WKWebView.self, is: .webkitPage), .textInputClient(is: .textView),
            .view(SidebarContainerView.self, is: .sidebar), .view(LayoutRootView.self, is: .layout),
        ]))
    private var mouseDownSubscription: InputSubscription?  // a click after dispatch (start)
    private(set) lazy var keyRouter: KeyRouter = KeyRouter(registry: registry, inputDispatch: inputDispatch)  // first read in init (no IUO)
    private(set) lazy var routeKeyDown: (NSEvent, NSWindow?) -> Bool = PerfLabCanaryKeyDown(features: { [weak self] in self?.features })
        .wrap { [weak self] (event: NSEvent, window: NSWindow?) in self?.keyRouter.interceptKeyDown(event, in: window) ?? false }  // debug.key calls it too
    private(set) lazy var menuTracking = MenuTrackingState()  // the one NSMenu tracking observer (not the run loop's eventTracking mode)
    // Idle steps on the main-thread scheduler, gated on the person's input and on menus; first read by its afterFirstFrame start.
    private(set) lazy var chromiumWarmup: ChromiumWarmup = ChromiumWarmup(
        engine: cache.cef, idle: mainDeadlines, input: inputTap, memory: memoryCoordinator,
        isTrackingMenu: { [menuTracking = self.menuTracking] in menuTracking.isTracking },
        observeMenuEnd: { [menuTracking = self.menuTracking] in menuTracking.observeEnd($0) })
    /// The Settings window (Settings…, Cmd-,).
    private(set) lazy var settingsWindow = SettingsWindowService(services: self)
    /// The wallpaper choices, built off main and kept current by folder events (BackdropCatalogStore).
    private(set) lazy var backdropCatalog = BackdropCatalogStore(systemDirectory: AppleWallpapers.system.desktopPictures, userImages: SettingsWindowService.userImages)
    let chiefPetHomes = ChiefPetHomes()  // the Chief Settings popovers the Chief pet's Chief Pet Settings… opens
    /// Each Chief's own pet character (the default Chief's is `home.chiefPetMascot`).
    let chiefMascotPicks = ChiefMascotPicks(defaults: .standard, defaultChief: HomeChiefAvatars.defaultChief)
    /// Debug Settings: tunable overrides and their window (DEV and NIGHTLY).
    private(set) lazy var debugSettings = DebugSettingsService(services: self)
    /// Debug menu > Toggle Action Latency HUD (DEV and NIGHTLY): the newest runs of `actionBudget`.
    private(set) lazy var actionLatencyHUD = ActionLatencyHUD(monitor: actionBudget)
    /// Quit: origin, the keep-or-end sheet and the end of the local sessions.
    private(set) lazy var quit = QuitCoordinator(services: self)
    /// Background mode (cx-ghagp): no window open means no Dock icon or Cmd-Tab entry, and a menu bar item instead.
    /// Only the process's own services drive it, and not while quitting (window teardown runs inside a quit).
    private(set) lazy var background = BackgroundActivation(registry: registry, icon: .icon(.appCmux, size: 16)) { [weak self] in
        guard let self else { return false }
        return AppProcessRoot.shared.services === self && self.windows.controllers.isEmpty && !self.quit.isQuitting
            && self.settings?.snapshot.hideDockIconWithoutWindows ?? CmuxConfigSnapshot.hideDockIconWithoutWindowsFallback }
    /// First-run onboarding, browser import and default-app claims.
    private(set) lazy var onboarding = OnboardingService(services: self)
    /// Agent permission requests (`permissions.request`): the card, the store and the TCC reads.
    private(set) lazy var agentPermissions = AgentPermissionsService(services: self)
    /// Provider sign-ins and CodeRouter accounts (Settings > Accounts, onboarding).
    private(set) lazy var accounts = AccountsService(services: self)
    /// Agent harness profiles (Settings > Agents, `agent.harness.*`), through acpmux.
    private(set) lazy var agentHarnesses = AgentHarnessCenter(services: self)
    /// Links, files and services macOS hands cmux (default browser, ssh:, scripts).
    private(set) lazy var externalOpen = ExternalOpenController(services: self)
    let terminalTheme = TerminalThemeSetting(backdropScope: .app)
    /// This Mac's layout templates (Save Layout as Template, New Workspace from Template).
    private(set) lazy var layoutTemplates = LayoutTemplateLibrary(repository: LayoutTemplateRepository(fileURL: environment.layoutTemplatesFile))
    /// Room, workspace and terminal themes.
    /// Every daemon answers terminal color queries with the colors terminals are painted with.
    private(set) lazy var terminalColors = TerminalColorSync(machines: machines, on: mainWork) {  // first read by the daemon start (`startLocalDaemon`), before it connects
        GhosttyRuntime.shared.themeColors.map(TerminalDefaultColors.init)
    }
    private(set) lazy var themes: ThemeCoordinator = ThemeCoordinator(services: self, terminalThemes: .forApplication(bundleIdentifier: environment.launch.bundleID))  // built by its start (`Themes.start`)
    /// Browser tabs of remote machines reach that machine's localhost.
    var remoteLocalhost: RemoteLocalhostService { madeRemoteLocalhost ?? RemoteLocalhostService.made(for: self) }  // on first use
    var madeRemoteLocalhost: RemoteLocalhostService?
    /// Which machines run browser tabs there, and their runtimes (cx-2cob slice 2).
    private(set) lazy var machineBrowserHosts = MachineBrowserHosts(machines: machines) { [weak self] in self?.remoteLocalhost }
    var chromiumLikelyObservations: [Task<Void, Never>] = []
    /// Follows the default engine for the pages spare window (`startChromiumWarmup`, feature `pagesSpareWindow`).
    var pagesSpareWatch: ServiceObservation<Bool>?
    /// Repaints on `appearance.borders` changes (`observeBorders`).
    var borderObservation: Task<Void, Never>?
    /// Repaints when the glass mode pages draw changes (`observeGlass`).
    var glassWatch: GlassModeWatch?
    /// Energy Saver's one owner of power inputs (Low Power Mode, power source, battery, thermal state);
    /// its Low Power Mode goes out by init and its inputs are pushed (`startEnergy`), never a shared instance.
    let energyMonitor: EnergyMonitor
    /// Pushes the monitor's inputs to the consumers below the App and ``energy``'s policy driver (`startEnergy`).
    var energyLink: MainActorHandlerRegistration<EnergyInputs>?
    /// Stills ambient motion loops while the saver is on (`MotionEnergyLink`, p14-energy-027).
    var energyMotion: MotionEnergyLink?
    /// The writer of `mainWork.energy`, the policy every scheduler reads, and the idle wakeup histogram.
    private(set) lazy var energy = EnergyServices(source: mainWork.energy, isEnabled: features.isEnabled(.energySaver))
    /// Follows `energy.saver` into ``energy``'s policy driver (`followEnergySaver`).
    private var energySaverObservation: ServiceObservation<EnergySaverMode?>?
    /// Posts this launch's installed-update Feed card once (`UpdateFeedPosting.follow`).
    var updateFeedObservation: Task<Void, Never>?
    /// Page menus and the open-menu diagnostic shared by browser hosts.
    let contextMenus: BrowserContextMenuBuilder
    /// Sized browser popups (OAuth, payment), each in its own Chrome-style popup window.
    let popups: BrowserPopupWindows
    /// The link-hint session (`f`, `F`) on a focused Chromium page.
    let linkHints = LinkHintController()
    /// Toggle React Grab on a page; the library is fetched once per run (`ReactGrabScriptLoader`).
    let reactGrab = ReactGrab(scripts: ReactGrabScriptLoader())
    /// Click by Hint over the whole window (`hints.show`, Cmd-J).
    let windowHints = WindowHintController()
    /// Browser profiles: records, the new-tab cascade, each tab's store.
    private(set) lazy var browserProfiles = BrowserProfileService(services: self)
    /// Agent chat tabs and their shared acpmux host (New Agent Chat).
    private(set) lazy var agentTabs = AgentTabStore.wired(to: self)
    /// Which agent chat opened each file, for viewer quotes (viewer-comments-DESIGN.md).
    private(set) lazy var chatQuoteOpeners = ChatQuoteOpeners()
    /// The device-wide Chats index (nil without acpmux), watched once for every window.
    private(set) lazy var chatsFeed: ChatsFeed? = ChatsFeed.started(for: self)
    /// Relays the Chats index and editor sources into the daemon's project list.
    private(set) lazy var projectsImport = ProjectsImport(services: self)
    /// Shared Open Chat path for sidebar clicks and palette Return.
    private(set) lazy var chatsOpener = ChatsOpenCoordinator(services: self)
    /// `agentTabs` once made: a tab close releases its view without starting acpmux.
    var madeAgentTabs: AgentTabStore?
    /// Quick Agent Chat's floating composer (`palette.quickAgentChat`).
    private(set) lazy var quickComposer = makeQuickComposer()
    /// The sidebar Chief item's pet picture, one for every window: loaded once off the main thread, then a new
    /// window draws it in its first frame.
    private(set) lazy var chiefSidebarPicture = ChiefSidebarPicture(work: work, mainWork: mainWork)
    let pages = InternalPageTabStore()  // internal page tabs (Settings, Debug Settings, the App Store)
    /// Where imported bookmarks go (the bookmarks feature sets it); nil keeps them in the import store only.
    var importedBookmarkSink: (any ImportedBookmarkSink)?
    /// Browser tab favicons per profile, for tab strips.
    let favicons = TabFaviconStore(loader: BrowserFaviconLoader.shared)
    /// The one owner of hover cards in the app: at most one card, ever
    /// (plans/cmux-next/hovercards.md). Its dismissals listen on ``inputTap``.
    let hoverCards: HoverCardCoordinator
    /// What is above a window's content changed: overlays, the hover card, focus overlays (the overlays facet's wait).
    let overlayChanges = OverlayChangeFeed()
    #if DEBUG || CMUX_BENCH_HOOKS
    /// A terminal view's daemon screen or link changed (the terminals facet's wait): each step a view's attach driver
    /// maps signals it. The overlays' broadcaster type, so no second lock site: it only says "read again".
    let terminalScreenChanges = OverlayChangeFeed()
    var terminalScreenChanged: (@Sendable () -> Void)? { { [terminalScreenChanges] in terminalScreenChanges.signal() } }
    #else
    var terminalScreenChanged: (@Sendable () -> Void)? { nil }
    #endif
    /// Refusal messages for keyboard and menu runs.
    let refusalHUD = RefusalHUD()
    /// The app's one set of blocking-work lanes: file I/O, sync system calls and long CPU work run there,
    /// never on the cooperative pool (PATTERNS P14). Built once here and passed to each consumer's init.
    let work: BackgroundWork
    /// The app process's black box: its heap ring from init, its file steps on `.files` (task p09-observability-005).
    /// Only the real app process has one (``AppEnvironment/marksRun``); tests that build `AppServices` do not.
    let traceBlackBox: TraceBlackBoxFileSteps?
    /// The last quit's agent pages and chat composers, read off the main thread since the launch began.
    let launchImages: AgentPaneLaunchImages, relaunchWake: AgentPaneRelaunchWake
    /// The agent panes' launch images as one startup ref (made at the root with the launch's scheduler).
    let launchImageHold: LaunchImageHold
    /// The launch's scheduler: the right sidebar's icon build is one of its cpu-lane posts. Nil in tests with no launch.
    let launchStartup: StartupScheduler?
    /// The app's crash keys (p10-stability-207; `AppControl` makes them): windows' focus, Chromium and the local daemon set theirs.
    let crashKeys: CrashKeySlots?
    /// The burst bench's record of refusals, designed no-op Cmd-W presses and terminal grids (`debug.burst`).
    let burstTrace = BurstTrace()
    /// Every tab switch's `switch.tab` trace pair, in every build (`DebugTabSwitch`); tests replace it.
    var tabSwitch = TabSwitchSignpost()
    /// The inline VS Code server (`serve-web`) behind VS Code (Inline); starts on first use.
    let vscodeServeWeb = VSCodeServeWebService(
        planner: VSCodeServeWebLaunchPlanner(homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                                             environment: ProcessInfo.processInfo.environment),
        launcher: VSCodeServeWebProcessLauncher(), tokenDirectory: FileManager.default.temporaryDirectory
    )
    /// The browser host's engine provider (idle until the daemon offers the endpoint).
    private(set) var browserHost: AppBrowserHost?
    /// Remote-terminal tabs: mount, placeholder, snapshot, moves.
    var remoteTerminals: RemoteTerminalService { madeRemoteTerminals ?? RemoteTerminalService.made(for: self) }  // on first use
    var madeRemoteTerminals: RemoteTerminalService?
    /// Cross-build session discovery and acknowledge-then-close handoff.
    private(set) lazy var sessionTransfer = SessionTransferService(services: self)
    /// - Parameter launchReveal: The launch load-in the windows' sidebars and panes hold for
    ///   (`AppDelegate` passes the one its startup phase reveals on); tests get one of their own.
    /// - Parameter work: the app's one set of blocking-work lanes (task traits, PATTERNS P14); by default
    ///   one watched by `hangWatch`, unless a test passes its own.
    /// - Parameter mainWork: The app's main-thread scheduler (`AppDelegate` passes the one its control
    ///   socket uses); tests get one of their own, with no pending-input check.
    /// - Parameter hangWatch: the hang watch of every watched lane (``work``'s lanes; through ``daemon``, its
    ///   connection readers, terminal attachments and terminal output lanes): the process's
    ///   (`TraceRuntime.shared`) by default, a test's fake, or nil to watch nothing.
    /// - Parameter energyMonitor: The app's power inputs: the system's by default (nothing reads IOKit
    ///   until `startEnergy`, which only `AppDelegate` calls), or a test's over fixed inputs.
    /// - Parameter appearance: The appearance signals (the app's design settings'; a test's own).
    /// - Parameter launchStartup: The launch's scheduler (`AppDelegate` passes `LaunchOrder.startup`); nil (tests)
    ///   makes the right sidebar's icons on main when its first panel is built.
    init(environment: AppEnvironment, launchReveal: LaunchReveal = LaunchReveal(), agentPaneEnvironment: [String: String]? = nil,
         work: BackgroundWork? = nil, mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget()),
         launchImages: AgentPaneLaunchImages = AgentPaneLaunchImages(directory: nil), relaunchWake: AgentPaneRelaunchWake = AgentPaneRelaunchWake(file: nil),
         wireStats: DaemonWireStats? = nil, hangWatch: (any HangWatchScoping)? = TraceRuntime.shared.hangWatch,
         energyMonitor: EnergyMonitor = EnergyMonitor(), inputTap: InputEventTap = InputEventTap(),
         launchImageHold: LaunchImageHold = LaunchImageHold(), launchStartup: StartupScheduler? = nil,
         crashKeys: CrashKeySlots? = nil, appearance: AppearanceSignals = DesignSettings.shared.signals) {
        self.appearance = appearance
        let work = work ?? BackgroundWork(hangs: hangWatch)
        self.work = work
        self.energyMonitor = energyMonitor
        // First: the black-box ring is attached to TraceRuntime.shared, so every trace point records from here
        // on; the ring file opens on `.files`, never on main.
        traceBlackBox = environment.marksRun ? TraceBlackBoxFileSteps.startApp(bundleID: environment.launch.bundleID, work: work) : nil
        (self.wireStats, self.inputTap) = (wireStats, inputTap)
        hoverCards = HoverCardCoordinator(input: inputTap, changes: overlayChanges)
        _ = CmuxDialogCenter.shared.observe { [overlayChanges] _ in overlayChanges.signal() } // an app dialog's host has no window
        (self.launchImages, self.relaunchWake, self.launchImageHold) = (launchImages, relaunchWake, launchImageHold)
        (self.launchStartup, self.crashKeys) = (launchStartup, crashKeys)
        // Estimated presents read the key display's last tick; no link starts for them.
        actionBudget = ActionBudgetMonitor(board: mainWork.budget.board, displays: FrameScheduler.appDisplays)
        updater = UpdaterService(work: work)
        chromiumRuntime = ChromiumRuntimeService.make(work: work)
        mobile = MobileHostService(displayName: { await MacName().displayName() }, work: work)
        #if DEBUG || CMUX_BENCH_HOOKS
        registry = ActionRegistry.standard(runTiming: SignpostActionRunTiming(monitor: actionBudget, crashKeys: crashKeys),
                                           turnObserver: oracleTurns, causes: mainWork.causes)
        #else
        registry = ActionRegistry.standard(runTiming: SignpostActionRunTiming(monitor: actionBudget, crashKeys: crashKeys),
                                           causes: mainWork.causes)
        #endif
        DaemonService.launchMark = { DebugTimings.markLaunch($0) }  // before any daemon service starts
        self.mainWork = mainWork
        // Its scroll events are timed to their frame (`key.scroll_frame`) by their latency slots (``inputLatency``).
        inputDispatch = InputDispatchContext(discreteInput: { [mainWork] in mainWork.noteDiscreteInput(expectsFrame: $0) },
                                             discreteDispatch: { [mainWork] in mainWork.noteDiscreteDispatch(began: $0) })
        daemon = DaemonService(echoesPlacementShift: SidebarMirror.isLinked, mainWork: mainWork, wireStats: wireStats,
                               hangWatch: hangWatch, crashKeys: crashKeys)
        self.launchReveal = launchReveal
        sidebarSnapshots = SidebarSnapshotStore(file: environment.sidebarSnapshotFile)
        let contextMenus = BrowserContextMenuBuilder.shared
        self.contextMenus = contextMenus
        popups = BrowserPopupWindows(contextMenus: contextMenus, mainWork: mainWork)
        self.environment = environment; self.agentPaneEnvironment = agentPaneEnvironment
        crashRecovery = CrashRecoveryService(bundleID: environment.launch.bundleID, marksRun: environment.marksRun, crashKeys: crashKeys)
        features = FeatureList(registry: FeatureRegistry(), channel: Feature.Channel(environment.build.kind), overrides: FeatureOverrides(environment: ProcessInfo.processInfo.environment.merging(["CMUX_ENABLE_FEATURES": "agentPageRendererSharing,automationBurstSnap,cefLayerHosting,cefPrefetchBehindFence,cefPumpInputPolicy,cefTimerSlack,chromiumHostIdleExit,chromiumHostWidgets,chromiumSpareAfterFirstTab,cmuxPageRendererSharing,coldScrollbackCompression,controlSocketEarlyBind,daemonRequestQos,energySaver,frameRateClasses,frozenGrowthDiscard,intentPrewarmHover,memoryAgentAndControlCaches,memoryAppCaches,memoryBrowserCaches,memoryDiscardAgentPagesOverBudget,memoryDiscardConversations,memoryDiscardInternalPages,memoryDiscardPageTabs,memoryDiscardParkedIdleTimeout,memoryDiscardParkedWorkspaces,memoryDiscardRemoteTabs,memoryFileHomeCaches,memoryHiddenFrameLRU,memoryImageCaches,memorySaverBackgroundActivity,memoryTerminalLastFrames,newTabParksHidden,occludedWindowDiscard,overlayTopLayer,pageLifecycle,pageProcessGroups,pageRendererAtFirstShow,pagesSpareWindow,pointerFrameDrags,pointerFrameHover,pointerFrameRemoteInput,recentlyAudibleProtection,renderStarvationGuard,rendererlessSpareWindow,sentryHandlersFirst,sidebarRowsNearViewport,stripPanResampling,taskManagerMemorySaved,terminalGPURelease,terminalPointerFrames,topPageDiscard,vsyncHub"]) { current, _ in current }))
        crashReporting = AppCrashReporting(environment: environment, afterStartup: .init(handlersFirst: features.isEnabled(.sentryHandlersFirst), startup: launchStartup))  // after the run marker's handlers
        DebugTimings.markLaunch("services.crash_reporting")
        machines = MachineRegistry(local: daemon)
        machines.isFeatureDisabled = { [registry] in registry.disabledFeatures.contains($0) }
        BrowserLifecycleTrace.shared.configure { tab, event in
            InputJournal.shared.append(window: nil, .content(tab: tab, event: event))
        }
        _ = cache  // built here, as before
        pages.createTabs = cache.createTabs  // a page tab's close ends its create.tab wait
        DebugTimings.markLaunch("services.cache")
        let runtime = GhosttyRuntime.shared
        let previousConfigChange = runtime.onConfigChange
        runtime.onConfigChange = { [weak self] in
            previousConfigChange?()
            self?.terminalColors.apply()
        }
        cache.configureBrowser = { [weak self] tab, url, base in  // a Cloud proxied tab's store first (ProxiedBrowserTabs)
            let base = self?.cache.pageRequests.closedHistories.restoring(base, url: url, local: self?.machines.daemon(forTab: tab).isLocal == true, tab: tab.id) ?? base  // cx-d0d.59
            return await self?.cache.pageRequests.proxiedTabs.configuration(for: tab.id, url: url, base: base) { await self?.localhostConfiguration(for: tab, url: url, base: base) ?? base } ?? base
        }
        cache.findTab = { [weak self] key in self?.machines.daemons.lazy.compactMap { $0.store.tab(id: key) }.first }  // any machine's tab
        cache.onRelease = { [weak self] key in
            self?.home.releaseTabView(key)
            self?.madeAgentTabs?.releaseIfGone(key)
            self?.cache.pageRequests.closedHistories.save(self?.cache.existingBrowser(key)?.tab)
        }
        cache.machineBadge = { [weak self] key, url in self?.browserMachineBadge(key: key, url: url) }
        cache.defersRestoredPages = crashRecovery.recovery.skipsBrowserPages
        cache.browserTabs.isIncognitoTab = { [weak self] key in
            guard let self, let workspace = workspaceID(ofTab: key) else { return false }
            return windows.isIncognito(workspace: workspace)
        }
        wireBrowserTabMachines()
        cache.browserProfile = { [weak self] key in self?.browserProfiles.engineProfile(forTab: key) }
        cache.profileBadge = { [weak self] key in self?.browserProfiles.omnibarBadge(forTab: key) }
        cache.profileBadgeMenu = { [weak self] key in
            guard let self, let tab = cache.tabModel(key) else { return nil }
            let target = ActionTargetRef(kind: .browserProfile, id: browserProfiles.profileID(ofTab: tab))
            // The badge's tab names the place: New Tab with Browser Profile and Manage Extensions
            // open in that tab's pane, not in whichever pane has the focus (on Home, the chat dock).
            return self.registry.makeContextMenu(for: .browserProfile, target: target,
                                                 arguments: ["tab": .target(ActionTargetRef(kind: .tab, id: tab.id))])
        }
        cache.browserTabs.browserEnabled = { [weak self] in self?.settings?.snapshot.linkRouting.browserEnabled ?? true }
        cache.browserTabs.resolveProfile = { [weak self] pane, explicit in
            guard let self else { return explicit }
            return browserProfiles.profileForNewTab(in: pane.handle, on: machines.daemon(forPane: pane), explicit: explicit)
        }
        cache.sessionDelegate = terminalDelegate
        cache.pageRequests.services = self
        _ = keyRouter  // built here, as before
        keyRouter.services = self
        keyRouter.whichKey = WhichKeyController()
        cache.keyRouter = keyRouter
        cache.onPageFocusRequest = { [weak self] key in self?.returnFocusToPage(key) }
        cache.onTerminalConfirmed = { [weak self] tab, daemon in self?.terminalConfirmed(tab, on: daemon) }
        cache.onBrowserEntryCreated = { [registry, weak self] entry in
            guard let self else { return }
            PageInfoHandlers.installRouter(on: entry, registry: registry)
            CertificateWarningHandlers.installRouter(on: entry, registry: registry)
            BrowserToolbarHandlers.install(on: entry, services: self)
            installOmnibarHooks(on: entry)
            bookmarks.attach(entry)
            onboarding.browserImportOffer.attach(entry)
            attachMachineBadgeMenu(entry)
        }
        cache.onSuggestionEngineCreated = { [weak self] in
            guard let self else { return }
            BookmarkSuggestionFeed.follow(bookmarks, profile: bookmarks.profile(of: $1), into: $0)
        }
        cache.onRevealTab = { [weak self] key in _ = self?.revealTab(key) }
        cache.makeExtensionMenuHandler = { [weak self] key in self.map { ExtensionMenuRouter(services: $0, tabKey: key) } }
        cache.onDevToolsChange = { [weak self] key, state, focused in self?.devToolsDidChange(key, state: state, focused: focused) }
        registry.menuKeyEquivalentGate = { [weak self] id in self?.keyRouter.allowsMenuKeyEquivalent(id) ?? true }
        let inputDispatch = inputDispatch
        (NSApp as? CmuxApplication)?.inputDispatch = inputDispatch
        (NSApp as? CmuxApplication)?.inputLatency = inputLatency
        registry.dispatchingInputEvent = { inputDispatch.event }
        registry.isDispatchingKeyDown = { inputDispatch.isKeyDown }
        registry.effectExpectsFrame = { inputDispatch.noteFrameExpected() }
        (NSApp as? CmuxApplication)?.keyDownInterceptor = { [weak self] event, window in
            guard let self else { return false }
            return sleepyMode.consumesKeyDown() || routeKeyDown(event, window)  // a key on Sleepy Mode's scene only wakes it
        }
        (NSApp as? CmuxApplication)?.crossWindowKeyGuard = { [weak self] event, keyWindow in
            // Keys typed after New Window follow its new window on purpose (NewTabInputCoordinator).
            guard let self, !keyRouter.newTabInputCoordinator.followsNewWindow else { return false }
            return CrossWindowInputGuard(windows: windows).dropsKey(event, keyWindow: keyWindow)
        }
        (NSApp as? CmuxApplication)?.dispatchScope = { [weak self] event, body in
            guard let self else { return body() }
            windows.dispatching(eventFrom: event.window, body)
        }
        (NSApp as? CmuxApplication)?.actionTargetOverride = { [weak self] action, found in
            self?.keyRouter.pasteTarget(for: action, found: found, in: NSApp.keyWindow)
        }
        surfaceInvariant.services = self
        cache.presentationChanges.subscribe("surface-invariant") { [weak self] in self?.surfaceInvariant.noteChange() }
        cache.presentationChanges.subscribe("browser-host") { [weak self] in // not for a change of only terminals and agent pages
            guard let self else { return }
            let onlyTerminalsAndAgents = self.cache.presentationChanges.changedKeys?.allSatisfy { self.cache.existingTerminal($0) != nil || self.madeAgentTabs?.existingView($0) != nil }
            if onlyTerminalsAndAgents != true { self.browserHost?.provider.refreshTabs() }
        }
        _ = windows  // built here, as before
        DebugTimings.markLaunch("services.windows")
        windows.incognitoHistoryReset = { [weak cache, weak self] in
            cache?.resetIncognitoHistory()
            self?.locationTrail.forgetIncognito()
        }
        WorkspaceClose.willClose = { [weak self] in if !RemoteTerminalService.remoteTabIDs(in: $0).isEmpty { self?.remoteTerminals.workspaceClosing($0) } }
        daemon.workTracker = { [registry] in registry.track($0) }
        palettes.whenBuilt { [weak self] in self?.paletteBuilt($0) }  // no palette at launch (p08-startup-023)
        terminalDelegate.services = self
        // Wiring only: the starts behind them are launch posts (`serviceStartPosts()`, p08-startup-031).
        let updateSheet = self.updateSheet  // built here, as before
        updater.wire(sheet: updateSheet, services: self, simulating: { SidebarTunables.simulatePendingUpdate.value })
        serverUpdates.bind(registry: registry)
        input.startNoActivateGuard(tap: inputTap, work: work, mainWork: mainWork)  // an NSApp input hook: before the app activates
        notifications.wire(services: self)
        cache.onBrowserReady = { [weak self] key in
            for controller in self?.windows.controllers ?? [] {
                for pane in controller.content?.panes.values.map({ $0 }) ?? [] where pane.currentTabKey == key { pane.showSelected() }
            }
        }
        DebugTimings.markLaunch("services.palette_updater")
        keyRouter.onTyping = { [weak self] window in self?.notifications.noteTyping(in: window) }
        // A mouse-down after AppKit dispatched it (focus has moved to the clicked pane). A click anywhere
        // ends link hints and a waiting chord (it may move the keyboard).
        mouseDownSubscription = inputTap.subscribePresses(.mouseDown, phase: .afterDispatch) { [weak self] event in
            guard let self else { return }
            notifications.noteMouseDown(in: event.window, at: event.locationInWindow)
            browserHost?.noteInput(event)
            linkHints.cancel()
            windowHints.cancel()
            keyRouter.cancelChord()
        }
        AppMemoryConsumers(services: self).registerMemoryConsumers()  // AppServices+Memory.swift
    }
    /// Builds and starts the browser host's engine provider once, from its launch post (p08-startup-031). Its
    /// `start()` follows the settings `AppDelegate` set before it (`browser.showAgentCursor`).
    func startBrowserHost() { if browserHost == nil { browserHost = AppBrowserHost(services: self); browserHost?.start() } }
    /// Starts the energy monitor and the idle histogram, and pushes the inputs, now and on each change, to the consumers
    /// that cannot import CmuxNextEnergy: KeepAwake's battery rule, the video wallpaper, and the saver itself to the
    /// motion gates (ambient loops hold still). WebKit's render rate reads `mainWork.energy` itself. Only
    /// `AppDelegate` calls it, so an `AppServices` a test builds reads no IOKit (tests pass their own consumers).
    func startEnergy(keepAwake: KeepAwakeService = .shared, videos: BackdropVideoPlayers = .shared, design: DesignSettings = .shared) {
        energy.start(inputs: energyMonitor)
        energyMotion = MotionEnergyLink(mainWork.energy, design: design)
        energyLink = energyMonitor.follow { [weak self] inputs in
            keepAwake.setOnBattery(inputs.onBattery)
            videos.setEnergy(lowPowerMode: inputs.lowPowerMode, thermal: inputs.thermal)
            self?.energy.driver.update(inputs: inputs)
        }
    }
    /// Follows `energy.saver` into the policy driver once the settings have loaded, so the first policy it
    /// publishes already follows the setting. `AppDelegate` calls it at launch; a second call does nothing.
    func followEnergySaver(_ settings: SettingsController) {
        guard energySaverObservation == nil else { return }
        // Nil until the settings first load; then each new mode, once (an equal one is not applied again).
        // `visible`: the policy changes frame rates and animation on screen.
        energySaverObservation = ServiceObservation(.visible, owner: "AppServices.energySaver", on: mainWork) {
            settings.loadCount >= 1 ? settings.snapshot.energySaver : nil
        } apply: { [weak self] mode in if let mode { self?.energy.driver.update(setting: mode) } }
    }
    // MARK: Lookup
    /// The tab with durable id (or tab resource id: links and TabMirror's wait use it) `id`
    /// and the pane that holds it, on any machine: one lookup of its machine (``MachineTabIndex``).
    func locateTab(_ id: String) -> (TabModel, PaneModel)? {
        machines.tabIndex.locate(id)
    }
    /// The tab on `surface` (the local daemon's surfaces).
    func locateTab(surface: SurfaceID) -> TabModel? {
        _ = daemon.store.tabListRevision // a tracked wait hears the tab appear
        return daemon.store.tab(surface: surface)
    }

    func workspace(id: String) -> WorkspaceModel? {
        machines.workspace(id: id)?.0
    }
    /// The daemon that owns `pane`.
    func daemon(for pane: PaneModel) -> DaemonService {
        machines.daemon(forPane: pane)
    }

    /// The workspace key of `pane`, for `SpawnOptions.workspace`: a new
    /// terminal there gets `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID`.
    func workspaceKey(of pane: PaneModel) -> WorkspaceKey? {
        daemon(for: pane).store.workspace(containing: pane.handle)?.key
    }

    /// Durable resource ids of `pane` and its screen and workspace
    /// (`terminal.project` destinations); nil on pre-registry daemons.
    func resourcePath(of pane: PaneModel) -> PaneResourcePath? {
        guard let workspace = daemon(for: pane).store.workspace(containing: pane.handle),
              let screen = workspace.screens.first(where: { $0.panes.contains { $0 === pane } }),
              let workspaceID = workspace.resourceID, let screenID = screen.resourceID, let paneID = pane.resourceID else { return nil }
        return PaneResourcePath(workspace: workspaceID, screen: screenID, pane: paneID)
    }

    /// Ends a detached tab drag whose move failed: the tab reappears.
    func restoreDetachedTab(_ id: String) {
        for controller in windows.controllers {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                pane.view.stripView.restoreDetachedTab(StripTabID(id))
                pane.resyncStrip()
            }
        }
    }

    /// The pane controller showing `pane` in the active window, if any.
    /// The controller showing `pane` itself. Handles are daemon-local
    /// numbers that repeat across machines, so a handle match counts only
    /// when the controller shows this very model.
    func paneController(for pane: PaneModel) -> PaneController? {
        for controller in windows.controllers {
            if let found = controller.content?.pane(for: pane.handle), found.pane === pane { return found }
        }
        return nil
    }
}
