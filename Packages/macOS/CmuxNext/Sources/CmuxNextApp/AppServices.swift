import AppKit
import CmuxNextActions
import CmuxNextAgentLanes
import CmuxNextOnboarding
import CmuxNextApps
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextBrowserHistory
import CmuxNextChiefPetWiring
import CmuxNextChromiumWarmup
import CmuxNextCloud
import CmuxNextCompat
public import CmuxNextComputerUse
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDesign
import CmuxNextMobileHost
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDaemonRecovery
public import CmuxNextDictation
import CmuxNextFeed
import CmuxNextFloating
import CmuxNextFavicons
import CmuxNextHibernation
import CmuxNextHomeEngine
import CmuxNextIcons
import CmuxNextPalette
import CmuxNextAccounts
import CmuxNextPages
import CmuxNextPopups
import CmuxNextBrowserImport
import CmuxNextPhone
import CmuxNextPhoneAccess
import CmuxNextServer
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextSignposts
import CmuxNextTerminal
import CmuxNextUpdater
import CmuxNextVSCodeServer
import CmuxNextWakeups
import CmuxNextWorkspaceNaming
import CmuxNextWorkspaceRepair
import os
import CmuxNextFocusUI
import CmuxNextTabs
/// Process-wide services the window controllers share. Model state is not
/// here: the daemon owns it, windows own their local state.
final class AppServices {
    /// The app's theme store (the one ``ThemeScope/app`` roots on), handed to the App's theme owners.
    let themeStore = ThemeScope.app.store
    /// The one scope that keeps every window backdrop's glass in its key look (ActiveLookScope), passed to each window.
    let activeLook = ActiveLookScope()
    /// The batch closes of selected sidebar rows under way, read by every batch close and Close Workspace.
    let selectionCloses = WorkspaceSelectionCloseFlow.Running()
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
    /// The local daemon. Cloud machines are in `machines`; code acting on a
    /// workspace, pane, or tab resolves its daemon through `machines`.
    /// The local daemon; a build with the sidebar document orders rows from it only (placement-shift-v1).
    /// Its event batches run on the app's ``MainWorkScheduler`` (``mainWork``), which every
    /// remote machine's service shares.
    let daemon: DaemonService
    let personalPlacements = PersonalPlacementQueue()
    /// The app's one main-thread scheduler (from the composition root), passed by init to the
    /// local daemon and to the Cloud, SSH and server services for their machines.
    let mainWork: MainWorkScheduler
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
    /// The editor `file.open {where: editor}` opens with; tests replace it to record the open.
    var editorApps: any AgentPaneEditorApps = AgentPaneWorkspaceEditors()
    /// The app's key window, from the composition root (AppServices never reads the global `NSApp`, nil in a
    /// test process). Tests and `debug.key` replace it: a window only becomes key in a running, active app.
    var keyWindowSource: @MainActor () -> NSWindow?
    /// Whether the app is active, from the composition root (never the global `NSApp`); tests replace it.
    var appActiveSource: @MainActor () -> Bool
    /// Restart CLI Listener: binds the control socket again. Set once the
    /// app's control socket starts; nil while it has none (tests, socket off).
    var restartControlListener: (@MainActor () throws -> Void)?
    /// This build's error journal (AppControl starts it): Help > Copy Logs reads it.
    var errorJournal: ErrorJournalService?
    /// Agents' and scripts' Cloud machine creates waiting on the person in every window's sidebar card.
    let machineAsks = SidebarAsks()
    /// Set and Clear Space Terminal Defaults…: one run at a time per space.
    let roomDefaults = RoomDefaultsUpdates()
    /// Auto-archive of idle workspaces (plans/cmux-next/auto-archive-DESIGN.md); started at launch.
    private(set) lazy var autoArchive = AutoArchiveCoordinator(host: self, ledgerStore: AutoArchiveLedgerStore(defaults: .standard))
    /// Each window's own Home (cmux#27880).
    private(set) lazy var windowHomes = WindowHomes(host: self)
    /// Hibernates idle workspaces (plans/cmux-next/workspace-hibernation-DESIGN.md).
    private(set) lazy var workspaceHibernation = WorkspaceHibernation(host: self, keepAwake: WorkspaceKeepAwakeStore(defaults: .standard),
                                                                  deadline: DemandTimer(owner: "workspace-hibernation"))
    private(set) lazy var cloud: CloudService = CloudService(machines: machines, isDebugBuild: ControlService.isDebugBuild, mainWork: mainWork, work: work, loginKeychain: loginKeychain, authCaptureFixture: environment.authCaptureFixture)  // first read in init (no IUO)
    /// The feed mirror (`FeedDO`), started once the cmux account is signed in.
    private(set) lazy var feed: FeedService = FeedService(
        auth: cloud.auth,
        showcase: environment.showcase,
        acpmuxEnvironment: QuitAgents.environment(self),
        appActive: { [weak self] in self?.appActiveSource() ?? false }
    )  // first read in init (no IUO)
    var showcase = ShowcaseState()
    /// The wide Inbox page, backed by `feed.model`.
    private(set) lazy var feedPage = FeedPageService(services: self)
    /// SSH machines (Connect to Machine…); `serverReach`: paired servers' Chief sessions in the sidebar.
    private(set) lazy var ssh: SSHService = SSHService(machines: machines, bundleID: environment.launch.bundleID, mainWork: mainWork)  // first read in init (no IUO)
    private(set) lazy var serverReach = ServerReachService.app(services: self)
    /// Add Machine and Check Machine (plans/cmux-next/add-machine-DESIGN.md); each machine's last check.
    private(set) lazy var addMachine = AddMachineCard(services: .app(self))
    /// Add Device and Settings > Devices (plans/cmux-next/add-device-DESIGN.md): one entry, one list, one remove.
    private(set) lazy var addDevice = AddDeviceCard(services: .app(self))
    private(set) lazy var devices = DeviceDirectory.app(self)
    #if DEBUG
    /// The `debug.*` capture fixtures this app reads while set (a test's services hold their own).
    let debugFixtures = DebugFixtures()
    /// One app's DEBUG capture fixtures: each set by its debug call, read where a Release build reads the live state.
    final class DebugFixtures {
        /// `debug.cloud_machine_fixture`: the registry context holds `cloudWorkspace` (AppServices+Cloud).
        var holdsCloudWorkspace = false
        /// `debug.add_device`: what Add Device shows (``AddDeviceServices/app(_:)``).
        var addDevice: DebugAddDevice.Listing?
        /// `debug.joined_machines`: the joined machines' calls in place of the CLI.
        var joinedMachines: MachineJoinService?
        /// `debug.join_consent`: the join status the app reads (``JoinConsentServices/app(_:)``), and its person line.
        var joinStatus: JoinStatus?
        let joinLine = DebugJoinConsent.FixtureLine()
        /// `debug.object_menu`: the tab or pane menu it opened last; nil after a workspace menu.
        weak var objectMenu: NSMenu?
    }
    #endif
    /// The Machines section's joined machines (Labs `labs.machineJoin`); empty while it is off.
    private(set) lazy var joinedMachines = JoinedMachineStore(service: { [weak self] in
        guard let self, self.settings?.snapshot.machineJoin == true else { return nil }
        #if DEBUG
        if let fixture = self.debugFixtures.joinedMachines { return fixture }
        #endif
        return MachineJoinService.app(self)
    })
    /// This Mac's one-line join consent (Settings > Devices' switches, the one-time sheet), behind labs.machineJoin.
    private(set) lazy var joinConsent = JoinConsentModel.app(self)
    /// The app's latest key or mouse input and whether it was the person's (HID system): backs a consent
    /// grant made in a page. Started at launch.
    let personInput = PersonInputLedger()
    /// Process-wide widening-switch gate shared by every Settings window.
    let wideningGate = PageWideningGate()
    /// Settings > Machines' "Dedicated agent machine" switch on each Cloud machine (acpmux vmHost).
    private(set) lazy var cloudVmHost = CloudVmHostStore(api: cloud.machineAPI)
    let machineHealth = MachineHealthStore()
    let mobile = MobileHostService(displayName: { await MacName().displayName() })  // phone access; the account layer starts it
    /// The process's one guard of the Keychain UI switch: every store of cmux's own Keychain items gets this one.
    let loginKeychain = LoginKeychain()
    /// iPhone connections for the cmux-next iPhone app (cmux-next-ios, Settings > Mobile).
    let iphone: IPhoneHostService
    /// Every action run's perform-to-commit time against the 10 ms budget (always on; zero-latency.md),
    /// each run published on the board of the app's ``MainWorkScheduler`` so the watchdog samples a slow one.
    let actionBudget: ActionBudgetMonitor
    /// Every action; timed by the always-on `action.*` signposts and `actionBudget`, in Debug and Release.
    let registry: ActionRegistry
    /// The main-thread blocking detector's handle (threading-model.md): the Debug menu, `debug.blocking`, and its log sink (``BlockingLogSink``).
    let blocking = BlockingDetector.forProcess()
    /// Sparkle updates (release builds) or read-only feed probes (DEV).
    let updater: UpdaterService
    /// The file picker made ahead of the click, the app's one: agent panes, page file inputs and Home's "+" take it.
    let openPanel = MadeAheadOpenPanel()
    /// "Restart cmux-tui to use new features" (plans/cmux-next/server-updates-DESIGN.md).
    private(set) lazy var serverUpdates = ServerUpdatePresenter(daemon: daemon, defaults: .standard,
                                                                 activeWindow: { [weak self] in self?.windows.active?.window })
    private(set) lazy var updateSheet: UpdateSheetController = UpdateSheetController(source: UpdateSheetModel(service: updater, openLink: { LinkRouter.shared.open($0) }))  // first read in init (no IUO)
    /// cmux.json controller; set by `AppDelegate` once it starts. Agent tabs made before it (by launch's action bindings) follow it from here.
    var settings: SettingsController? { didSet { if let settings, settings !== oldValue { onboarding.followImportSetting(settings); madeAgentTabs?.follow(settings); browserHost?.follow(settings); cloud.hostReplica.follow(settings, local: machines.local, account: { [cloud] in cloud.auth.isSignedIn && cloud.mayCallCloud && !cloud.policyDisabled ? cloud.auth.user?.id : nil }) } } }
    /// Writes the palette shortcut recorder's edits (the recorder holds it weakly).
    var paletteShortcutEditor: PaletteShortcutEditor?
    /// Where Chromium comes from: embedded, or downloaded on first use (bundle-size-DESIGN.md section 6).
    let chromiumRuntime = ChromiumRuntimeService.make()
    /// The browser stores both engines and the App share: the one answer to "is this profile off the record".
    let browserStores: BrowserSharedStores
    /// Chromium sign-in tabs: the engine's runtime and the sign-in windows share it.
    let signInCallbacks = CEFSignInCallbacks()
    /// Every terminal's grid sender: next frame, one in flight, a split's or close's final grid at once.
    let resizes = ResizeCoordinator()
    /// Browser tabs each pane also lists (`browser.page.mirror`): one live page shown in a second pane.
    let tabMirrors = TabMirrors()
    private(set) lazy var cache: TabContentCache = TabContentCache(daemon: daemon, cef: CEFEngine(source: chromiumRuntime.source, stores: browserStores, signInCallbacks: signInCallbacks, lifecycleTrace: .shared, contextMenus: self.contextMenus), fileInput: openPanel, resizes: resizes)  // first read in init (no IUO)
    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.window_record` and `--record-launch`'s recordings.
    let windowRecord = DebugWindowRecord()
    /// `debug.terminal_final_grid`: a split's or close's terminal grids, sent, drawn and announced.
    private(set) lazy var finalGridTrace: TerminalFinalGridTrace = {
        let trace = TerminalFinalGridTrace { [weak self] in self?.cache.terminals.map { ($0.key, $0.value.session, ObjectIdentifier($0.value.io)) } ?? [] }
        resizes.onSend = { [weak trace] in trace?.noteSend($0, columns: $1.cols, rows: $1.rows) }
        return trace
    }()
    #endif
    private(set) lazy var windows: WindowManager = WindowManager(services: self)  // first read in init (no IUO)
    private(set) lazy var dragSession: TabDragSession = TabDragSession(services: self)  // first read in init (no IUO)
    private(set) lazy var palette: PaletteController = {
        let palette = PaletteController(registry: registry, sources: PaletteSourcesBridge.make(services: self),
                                        usage: DaemonPaletteUsageStore(services: self))
        palette.hiddenActionIDs = {
            AgentPaneTunables.pointerInspector.value ? [] : ["agentPane.togglePointerInspector"]
        }
        return palette
    }()  // first read in init (no IUO)
    private(set) lazy var previews: TabPreviewSource = TabPreviewSource(cache: cache)  // first read in init (no IUO)
    /// CPU and memory for the hover cards and `resources` (sampled on demand).
    private(set) lazy var resources: AppResourceSource = AppResourceSource(services: self)  // first read in init (no IUO)
    let presentation = ContentPresentationScheduler()
    /// Blank-pane invariant, checked after each presentation settle.
    let surfaceInvariant = SurfaceInvariantMonitor()
    /// Input invariants, desync reports, focus journaling and the no-activate keyboard guard.
    let input = InputVerificationService()
    private(set) lazy var emptyWorkspaces: EmptyWorkspaceRepair = EmptyWorkspaceRepair(daemon: daemon)  // first read in init (no IUO)
    /// The closed-tab signal and the undo toasts of user closes; set when the tab handlers bind. The daemon owns the closed history (`DaemonClosedHistory`).
    var closedTabs: ClosedTabsFeed?
    /// Find Work's GitHub reads, with the user's `gh` login (``FindWorkPalettePage``); tests replace it.
    lazy var findWorkGitHub: any GitHubFeedAPI = GitHubCLIClient(executable: AgentChatPullRequestReader.findGitHubCLI() ?? "/usr/bin/env")
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
        return ModelRouterLease(tokens: cloud.auth, apiBaseURL: feed.apiBaseURL, acpmuxHome: acpmux.home,
                                logger: Logger(subsystem: "com.cmuxterm.next", category: "model-router"))
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
    /// The right sidebar's sections by mode (the file explorer adds Files and Find).
    private(set) lazy var rightSidebarSections: RightSidebarSections = {
        let sections = RightSidebarSections()
        sections.registerAppSections()
        sections.prewarmIcons()
        return sections
    }()
    /// `cmux://agent-activity`: the computer use sessions page.
    private(set) lazy var agentActivityPage = AgentActivityPageService(services: self)
    /// The live preview card of computer use in agent chats (`computerUse.livePreview`); its live
    /// view runs only while the person can see the chat's page.
    private(set) lazy var computerUsePreview = ComputerUseLivePreview(
        host: self, sight: ComputerUsePreviewViewSight { [weak self] in self?.agentTabs.views[$0] })
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
    /// Share Screen with Chief (docs/chief-screen-share.md), read by the Computer Use helper; journal in `optchat/screen`.
    lazy var chiefScreenShare = ChiefScreenShare(
        capture: ChiefScreenHelperCapture(host: ComputerUseScreenStills(helper: .shared)),
        journal: ChiefScreenJournal(directory: ChiefHome.resolve(tag: environment.tag).muxHome.appending(path: "optchat/screen", directoryHint: .isDirectory)))
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
    /// One prewarmed new tab page per window (instant open).
    private(set) lazy var newTabSpares = NewTabSparePool(services: self, memoryPressure: memoryPressure)
    /// The spare React page hosts for Settings, History and Cloud.
    private(set) lazy var pageHostPool = PageHostPool(memoryPressure: memoryPressure)
    /// The one icon picker (R94): Set Icon of workspaces, screens, spaces, browser profiles.
    private(set) lazy var iconPicker = IconPickerService(services: self)
    /// cmux.json command `actions`, registered as `cmuxConfig.<name>`.
    private(set) lazy var configActions: ConfigActionsController = ConfigActionsController(context: AppActionContext(services: self))  // first read in init (no IUO)
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
    private(set) lazy var uiInspector = UIInspectorController(services: self)
    /// The one keyboard router (plans/cmux-next/focus.md section 5).
    /// The input event being dispatched now (``InputDispatchContext``): `sendEvent` and the router's own dispatches.
    /// Each scroll event it dispatches is timed to its frame (`key.scroll_frame`).
    let inputDispatch = InputDispatchContext(scrollFrames: ScrollFrameSignpost())
    private(set) lazy var keyRouter: KeyRouter = KeyRouter(registry: registry, inputDispatch: inputDispatch, heldKeyReplay: heldKeyReplay)  // first read in init (no IUO)
    /// Where a creation hold's keys run again (``HeldKeyReplay``): `AppDelegate` passes `NSApp.sendEvent`.
    private let heldKeyReplay: HeldKeyReplay
    private(set) lazy var chromiumWarmup: ChromiumWarmup = ChromiumWarmup(engine: cache.cef)  // first read in init (no IUO)
    /// The Settings window (Settings…, Cmd-,).
    private(set) lazy var settingsWindow = SettingsWindowService(services: self)
    /// The wallpaper choices, built off main and kept current by folder events (BackdropCatalogStore).
    private(set) lazy var backdropCatalog = BackdropCatalogStore(systemDirectory: AppleWallpapers.system.desktopPictures, userImages: SettingsWindowService.userImages)
    let chiefPetHomes = ChiefPetHomes()  // the Chief Settings popovers the Chief pet's Chief Pet Settings… opens
    /// Each Chief's own pet character (the default Chief's is `home.chiefPetMascot`).
    let chiefMascotPicks = ChiefMascotPicks(defaults: .standard, defaultChief: HomeChiefAvatars.defaultChief)
    /// Each Chief's own uploaded avatar, kept on this Mac only (Application Support/<bundle id>/AvatarUploads).
    let chiefAvatarUploads = ChiefAvatarUploads(folder: ChiefAvatarUploads.defaultFolder)

    /// The picture Chief `chief` (a participant id; nil: the default Chief) wears where it has no
    /// avatar of its own: its worn upload's first frame, else its pet character's.
    func characterPicture(of chief: String?) -> URL? {
        ChiefPetSettingsRows.characterPicture(of: chief, picks: chiefMascotPicks, uploads: chiefAvatarUploads, in: settings?.snapshot)
    }

    /// Chief `chief`'s (nil: the default) upload while it is worn over the character picked now.
    func wornUpload(of chief: String?) -> ChiefAvatarUploads.Upload? {
        ChiefPetSettingsRows.wornUpload(of: chief, picks: chiefMascotPicks, uploads: chiefAvatarUploads, in: settings?.snapshot)
    }
    /// Debug Settings: tunable overrides and their window (DEV and NIGHTLY).
    private(set) lazy var debugSettings = DebugSettingsService(services: self)
    /// Debug menu > Toggle Action Latency HUD (DEV and NIGHTLY): the newest runs of `actionBudget`.
    private(set) lazy var actionLatencyHUD = ActionLatencyHUD(monitor: actionBudget)
    /// Quit: origin, the keep-or-end sheet and the end of the local sessions.
    private(set) lazy var quit = QuitCoordinator(services: self)
    /// Background mode (cx-ghagp): no window open means no Dock icon or Cmd-Tab entry, and a menu bar item instead.
    /// Only the process's own services drive it, and not while quitting (window teardown runs inside a quit).
    private(set) lazy var background = BackgroundActivation(registry: registry, icon: MenuBarIcon().image(), mayEnter: { [weak self] in
        guard let self else { return false }
        return AppProcessRoot.shared.services === self && self.windows.controllers.isEmpty && !self.quit.isQuitting
            && self.settings?.snapshot.hideDockIconWithoutWindows ?? CmuxConfigSnapshot.hideDockIconWithoutWindowsFallback
    }, menuBarItemShown: { [weak self] in self?.menuBarExtra.isShown ?? false })
    /// The cmux menu bar item (`app.showMenuBarIcon`): account, agents, help, community, updates, logs, Quit.
    private(set) lazy var menuBarExtra = MenuBarExtra(registry: registry, icon: MenuBarIcon().image(), host: self)
    /// First-run onboarding, browser import and default-app claims.
    private(set) lazy var onboarding = OnboardingService(services: self)
    /// Agent permission requests (`permissions.request`): the card, the store and the TCC reads.
    private(set) lazy var agentPermissions = AgentPermissionsService(services: self)
    /// Provider sign-ins and CodeRouter accounts (Settings > Accounts, onboarding).
    private(set) lazy var accounts = AccountsService(services: self)
    /// Agent harness profiles (Settings > Agents, `agent.harness.*`), through acpmux.
    private(set) lazy var agentHarnesses = AgentHarnessCenter(services: self)
    /// Every harness's icon (user 12922) for the tab strip and sidebar, and their drawings.
    private(set) lazy var harnessIcons = HarnessIconBook(environment: { [weak self] in self.flatMap(QuitAgents.environment) })
    let harnessIconArtwork = HarnessIconArtwork()
    /// The drawn harness icons the tab strip and sidebar mappings take.
    var harnessIconLookup: HarnessIconLookup { harnessIconArtwork.lookup(for: harnessIcons.icons) }
    /// Links, files and services macOS hands cmux (default browser, ssh:, scripts).
    private(set) lazy var externalOpen = ExternalOpenController(services: self)
    /// The `cmux://session/<id>` question before a link opens a new agent tab.
    private(set) lazy var sessionLinks = SessionLinkGate.app(self)
    let terminalTheme = TerminalThemeSetting(backdropScope: .app)
    /// This Mac's layout templates (Save Layout as Template, New Workspace from Template).
    private(set) lazy var layoutTemplates = LayoutTemplateLibrary(repository: LayoutTemplateRepository(fileURL: environment.layoutTemplatesFile))
    /// Room, workspace and terminal themes.
    /// Every daemon answers terminal color queries with the colors terminals are painted with.
    private(set) lazy var terminalColors = TerminalColorSync(machines: machines) {  // first read in init (no IUO)
        GhosttyRuntime.shared.themeColors.map(TerminalDefaultColors.init)
    }
    private(set) lazy var themes: ThemeCoordinator = ThemeCoordinator(services: self, terminalThemes: .forApplication(bundleIdentifier: environment.launch.bundleID))  // first read in init (no IUO)
    /// Browser tabs of remote machines reach that machine's localhost.
    private(set) lazy var remoteLocalhost = machines.makeRemoteLocalhost()  // first read in init (no IUO)
    /// Which machines run browser tabs there, and their runtimes (cx-2cob slice 2).
    private(set) lazy var machineBrowserHosts = MachineBrowserHosts(machines: machines, localhost: remoteLocalhost)
    var chromiumLikelyObservations: [Task<Void, Never>] = []
    /// Repaints on `appearance.borders` changes (`observeBorders`).
    var borderObservation: Task<Void, Never>?
    /// Repaints when the glass mode pages draw changes (`observeGlass`).
    var glassWatch: GlassModeWatch?
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
    /// The app's daemon update (its one queue and board) and what it knows of its local acpmux daemons.
    let daemonUpdates = DaemonUpdates(), acpmuxDaemons = AcpmuxLocalDaemons()
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
    let pages = InternalPageTabStore()  // internal page tabs (Settings, Debug Settings, the App Store)
    /// Where imported bookmarks go (the bookmarks feature sets it); nil keeps them in the import store only.
    var importedBookmarkSink: (any ImportedBookmarkSink)?
    /// Browser tab favicons per profile, for tab strips.
    let favicons = TabFaviconStore(loader: BrowserFaviconLoader.shared)
    /// The one owner of hover cards in the app: at most one card, ever
    /// (plans/cmux-next/hovercards.md).
    let hoverCards = HoverCardCoordinator()
    /// Refusal messages for keyboard and menu runs.
    let refusalHUD = RefusalHUD()
    /// The app's one set of blocking-work lanes: file I/O, sync system calls and long CPU work run there,
    /// never on the cooperative pool (PATTERNS P14). Built once here and passed to each consumer's init.
    let work: BackgroundWork
    /// The bundled `cmux` (`<Resources>/bin/cmux`): asking for it makes no file call on the main thread.
    let bundledCLI: BundledExecutable
    /// The last quit's agent pages and chat composers, read off the main thread since the launch began, and
    /// this app's peer-route approver key (``PeerApprovalsApp/approver()``, made at launch; nil in tests).
    let launchImages: AgentPaneLaunchImages, relaunchWake: AgentPaneRelaunchWake, peerApprover: AgentPanePeerApprover?
    /// The agent panes' state files (unsent drafts, scroll places): one writer per file; quit waits for them.
    let agentPaneStateFiles: AgentPaneStateFiles
    /// The state files a quit's deadline ended before they saved, told at the next launch.
    let agentPaneStateLoss: AgentPaneStateLoss
    /// The burst bench's record of refusals, designed no-op Cmd-W presses and terminal grids (`debug.burst`).
    let burstTrace = BurstTrace()
    /// The inline VS Code server (`serve-web`) behind VS Code (Inline); starts on first use.
    let vscodeServeWeb = VSCodeServeWebService(
        planner: VSCodeServeWebLaunchPlanner(homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                                             environment: ProcessInfo.processInfo.environment),
        launcher: VSCodeServeWebProcessLauncher(), tokenDirectory: FileManager.default.temporaryDirectory
    )
    /// The browser host's engine provider (idle until the daemon offers the endpoint).
    private(set) var browserHost: AppBrowserHost?
    /// Remote-terminal tabs: mount, placeholder, snapshot, moves.
    private(set) lazy var remoteTerminals: RemoteTerminalService = RemoteTerminalService(services: self)  // first read in init (no IUO)
    /// Cross-build session discovery and acknowledge-then-close handoff.
    private(set) lazy var sessionTransfer = SessionTransferService(services: self)
    /// - Parameter launchReveal: The launch load-in the windows' sidebars
    ///   hold for; the app-wide one by default.
    /// - Parameter work: the app's one set of blocking-work lanes (task traits, PATTERNS P14); a default
    ///   instance unless a test passes its own.
    /// - Parameter mainWork: The app's main-thread scheduler (`AppDelegate` passes the one its control
    ///   socket uses); tests get one of their own, with no pending-input check.
    init(environment: AppEnvironment, keyWindowSource: @escaping @MainActor () -> NSWindow?, appActiveSource: @escaping @MainActor () -> Bool, heldKeyReplay: @escaping HeldKeyReplay,
         launchReveal: LaunchReveal = .shared, agentPaneEnvironment: [String: String]? = nil,
         work: BackgroundWork = BackgroundWork(), mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget()),
         launchImages: AgentPaneLaunchImages = AgentPaneLaunchImages(directory: nil), relaunchWake: AgentPaneRelaunchWake = AgentPaneRelaunchWake(file: nil), peerApprover: AgentPanePeerApprover? = nil,
         agentPaneStateFiles: AgentPaneStateFiles = AgentPaneStateFiles()) {
        self.work = work
        bundledCLI = BundledExecutable(resources: Bundle.main.resourceURL, name: "cmux", work: work)
        (iphone, browserStores) = (IPhoneHostService(loginKeychain: loginKeychain), .application(loginKeychain: loginKeychain))
        (self.launchImages, self.relaunchWake, self.keyWindowSource, self.appActiveSource, self.peerApprover, self.heldKeyReplay) = (launchImages, relaunchWake, keyWindowSource, appActiveSource, peerApprover, heldKeyReplay)
        self.agentPaneStateFiles = agentPaneStateFiles
        agentPaneStateLoss = AgentPaneStateLoss(directory: environment.sidebarSnapshotFile?.url.deletingLastPathComponent())
        actionBudget = ActionBudgetMonitor(board: mainWork.budget.board)
        // Before the updater's What's New tracker writes its record: an install that ran before
        // never sees the Browser tip (AgentPaneFeatureTipRecords.settleInstall).
        AgentPaneFeatureTipRecords().settleInstall(launchedBefore: WhatsNewSeenStore(defaults: .standard).hasRecord)
        updater = UpdaterService(work: work)
        registry = ActionRegistry.standard(runTiming: SignpostActionRunTiming(monitor: actionBudget))
        DaemonService.launchMark = { DebugTimings.markLaunch($0) }  // before any daemon service starts
        self.mainWork = mainWork
        daemon = DaemonService(echoesPlacementShift: SidebarMirror.isLinked, mainWork: mainWork)
        // A cmux-tui that stays alive but never answers restarts by itself (`UnresponsiveOwnerWatch`).
        daemon.recovery.restartsUnresponsiveOwner = { DaemonTunables.restartUnresponsiveCmuxTUI.value }
        self.launchReveal = launchReveal
        sidebarSnapshots = SidebarSnapshotStore(file: environment.sidebarSnapshotFile)
        let contextMenus = BrowserContextMenuBuilder.shared
        self.contextMenus = contextMenus
        popups = BrowserPopupWindows(contextMenus: contextMenus, activeLook: activeLook)
        self.environment = environment; self.agentPaneEnvironment = agentPaneEnvironment
        crashRecovery = CrashRecoveryService(bundleID: environment.launch.bundleID, marksRun: environment.marksRun)
        // After the run marker's handlers: Sentry calls them after its report.
        crashReporting = AppCrashReporting(environment: environment)
        DebugTimings.markLaunch("services.crash_reporting")
        machines = MachineRegistry(local: daemon, updates: daemonUpdates.board)
        machines.isFeatureDisabled = { [registry] in registry.disabledFeatures.contains($0) }
        _ = cloud  // built here, as before
        _ = feed  // built here, as before
        _ = rightSidebarSections  // built at launch: its icons are made off the main thread before the first show
        _ = ssh  // built here, as before
        BrowserLifecycleTrace.shared.configure { tab, event in
            InputJournal.shared.append(window: nil, .content(tab: tab, event: event))
        }
        _ = cache  // built here, as before
        DebugTimings.markLaunch("services.cache")
        _ = themes  // built here, as before
        _ = terminalColors
        let runtime = GhosttyRuntime.shared
        let previousConfigChange = runtime.onConfigChange
        runtime.onConfigChange = { [weak self] in
            previousConfigChange?()
            self?.terminalColors.apply()
        }
        _ = remoteLocalhost  // built here, as before
        cache.configureBrowser = { [weak self] tab, url, base in  // a Cloud proxied tab's store first (ProxiedBrowserTabs)
            let base = self?.cache.pageRequests.closedHistories.restoring(base, url: url, local: self?.machines.daemon(forTab: tab).isLocal == true, tab: tab.id) ?? base  // cx-d0d.59
            // Nil (a blocked proxied tab, a remote-localhost route that cannot start) leaves the page
            // blank (TabContentCache.chromiumConfiguration), never on this Mac's localhost.
            return await self?.cache.pageRequests.proxiedTabs.configuration(for: tab.id, url: url, base: base) { await self?.remoteLocalhost.configuration(for: tab, url: url, base: base) }
        }
        cache.findTab = { [weak self] key in self?.remoteLocalhost.tab(id: key) }
        cache.onRelease = { [weak self] key in
            self?.home.releaseTabView(key)
            self?.madeAgentTabs?.releaseIfGone(key)
            self?.cache.pageRequests.closedHistories.save(self?.cache.existingBrowser(key)?.tab)
        }
        cache.machineBadge = { [weak self] key, url in self?.browserMachineBadge(key: key, url: url) }
        cache.crashedPages = crashRecovery.recovery.crashedPages
        cache.onRestoredPageStart = { [weak crashRecovery] key in crashRecovery?.marker?.notePageStarted(key) }
        // Any browser tab, by any path, is a use of the browser: its tip never shows (feature tips).
        cache.onBrowserTab = { AgentPaneFeatureTipRecords().noteFeatureUsed(AgentPaneFeatureTipRecords.browserFeature) }
        crashRecovery.observe(cache.cef.crashLog)
        AppRunMarker.keepSignalHandlers(crashRecovery.marker, across: cache.cef, reporter: crashReporting.reporter)
        cache.cef.openURLWithoutWindow = { [weak self] url, disposition, profile in
            // Chromium wanted a window and has none for that profile (a
            // normal one; an incognito store never gets here): a new browser
            // tab in the focused pane of a normal window (Chromium opens nothing),
            // in the requesting page's browser profile.
            self?.normalWindowForPageRequest()?.focusedPane?.newBrowserTab(url: url, background: disposition == .backgroundTab,
                                                                          profile: profile.map(BrowserProfileRecord.wireID(for:)))
        }
        cache.cef.openOffTheRecord = { [weak self] url, source in self?.openOffTheRecord(url, source: source) }
        // A Chromium page's file chooser that reaches the app with no agent offer asks with the same panel WebKit tabs use.
        cache.cef.fileInput = openPanel
        cache.browserTabs.isIncognitoTab = { [weak self] key in
            guard let self, let workspace = workspaceID(ofTab: key) else { return false }
            return windows.isIncognito(workspace: workspace)
        }
        wireBrowserTabMachines()
        cache.browserProfile = { [weak self] key in self?.browserProfiles.engineProfile(forTab: key) }
        cache.profileBadge = { [weak self] key in self?.browserProfiles.omnibarBadge(forTab: key) }
        // Customize Menu… at the end of a right-click menu opens Settings > Menus on that menu.
        registry.customizeMenu = { [weak self] context in self?.settingsWindow.showMenus(context) }
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
        _ = emptyWorkspaces  // built here, as before
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
            entry.chrome.onContentFullscreenChange = { [weak self, weak entry] on in
                if let entry { self?.pageContentFullscreenChanged(entry, on: on) }
            }
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
        registry.dispatchingInputEvent = { inputDispatch.event }
        registry.isDispatchingKeyDown = { inputDispatch.isKeyDown }
        (NSApp as? CmuxApplication)?.assistiveClientsChanged = { [weak self] active in self?.cache.cef.setAssistiveClientActive(active) }
        (NSApp as? CmuxApplication)?.keyDownInterceptor = { [weak self] event, window in
            guard let self else { return false }
            // A key on Sleepy Mode's scene only wakes it; no shortcut runs behind the cover.
            if self.sleepyMode.consumesKeyDown() { return true }
            return self.keyRouter.interceptKeyDown(event, in: window)
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
        surfaceInvariant.observeWindowOcclusion()
        cache.presentationChanges.subscribe("surface-invariant") { [weak self] in self?.surfaceInvariant.noteChange() }
        cache.presentationChanges.subscribe("browser-host") { [weak self] in // not for a change of only terminals and agent pages
            guard let self else { return }
            let onlyTerminalsAndAgents = self.cache.presentationChanges.changedKeys?.allSatisfy { self.cache.existingTerminal($0) != nil || self.madeAgentTabs?.existingView($0) != nil }
            if onlyTerminalsAndAgents != true { self.browserHost?.provider.refreshTabs() }
        }
        _ = resources  // built here, as before
        _ = windows  // built here, as before
        DebugTimings.markLaunch("services.windows")
        windows.incognitoHistoryReset = { [weak cache, weak self] in
            cache?.resetIncognitoHistory()
            self?.locationTrail.forgetIncognito()
        }
        _ = dragSession  // built here, as before
        _ = previews  // built here, as before
        _ = remoteTerminals  // built here, as before
        remoteTerminals.start()
        WorkspaceClose.willClose = { [weak self] workspace in self?.remoteTerminals.workspaceClosing(workspace) }
        let registry = registry
        daemon.workTracker = { registry.track($0) }
        // A pane verb on a pane still opening was not sent: the refusal path logs it and shows it (P0 rule a; every
        // machine's daemon copies this hook, as `workTracker`).
        daemon.paneNotReadyText = { MiscHandlerStrings.paneNotReady }
        daemon.onPaneNotReady = { [weak registry] reason in registry?.refuse(reason) }
        _ = palette  // built here, as before
        terminalDelegate.services = self
        _ = configActions  // built here, as before
        let updateSheet = self.updateSheet  // built here, as before
        updater.attach(sheet: updateSheet, services: self, simulating: { SidebarTunables.simulatePendingUpdate.value })
        serverUpdates.start(registry: registry)
        cache.onBrowserReady = { [weak self] key in
            for controller in self?.windows.controllers ?? [] {
                for pane in controller.content?.panes.values.map({ $0 }) ?? [] where pane.currentTabKey == key { pane.showSelected() }
            }
        }
        observePaletteForFocus()
        input.start(services: self)
        DebugTimings.markLaunch("services.palette_updater")
        _ = chromiumWarmup  // built here, as before
        browserHost = AppBrowserHost(services: self)
        browserHost?.start()
        notifications.start(services: self)
        keyRouter.onTyping = { [weak self] window in self?.notifications.noteTyping(in: window) }
        // Builds with the detector (Nightly, bench, Debug) log each new main-thread blocking site once
        // (kind + image UUID + offset frames only); Release compiles the detector out and this does nothing.
        blocking.install(sink: BlockingLogSink())
        (NSApp as? CmuxApplication)?.mouseDownObserver = { [weak self] event in
            let app = NSApp as? CmuxApplication
            self?.notifications.noteMouseDown(in: event.window, at: event.locationInWindow, left: event.type == .leftMouseDown,
                                              screen: event.type == .leftMouseDown ? app?.mouseDownScreenLocation : nil,
                                              synthetic: app?.currentEventIsSynthetic ?? false)
            self?.browserHost?.noteInput(event)
            // A click anywhere ends link hints and a waiting chord (it may move the keyboard).
            self?.linkHints.cancel()
            self?.windowHints.cancel()
            self?.keyRouter.cancelChord()
        }
        (NSApp as? CmuxApplication)?.keyDownObserver = { [weak self] _ in self?.notifications.endViewHolds() }
        (NSApp as? CmuxApplication)?.leftButtonObserver = { [weak self] event in
            if event.type == .leftMouseDragged {
                self?.notifications.noteMouseDragged(in: event.window, at: event.locationInWindow)
            } else {
                self?.notifications.noteMouseUp(in: event.window, at: event.locationInWindow)
            }
        }
    }
    // MARK: Lookup
    /// A durable or resource id without a machine is usable only when exactly one
    /// machine holds it. Forks can preserve ids; never pick one by registry order.
    func locateTab(_ id: String) -> (TabModel, PaneModel)? {
        var found: (TabModel, PaneModel)?
        for daemon in machines.daemons {
            guard let tab = daemon.store.tab(idOrResource: id), let pane = daemon.store.pane(holding: tab) else { continue }
            guard found == nil else { return nil }
            found = (tab, pane)
        }
        return found
    }

    /// Compatibility for callers whose state is still keyed by a bare tab id: the
    /// pre-#5338 first match across machines. Do not add callers; migrate these
    /// to machine-scoped state instead (the source guard ratchets the existing set).
    func locateTabOnAnyMachine(_ id: String) -> (TabModel, PaneModel)? {
        for daemon in machines.daemons {
            if let tab = daemon.store.tab(idOrResource: id), let pane = daemon.store.pane(holding: tab) { return (tab, pane) }
        }
        return nil
    }

    /// Resolves only in the named machine; a missing machine never falls back locally.
    func locateTab(_ id: String, onMachine machineID: String) -> (TabModel, PaneModel)? {
        guard let daemon = machines.daemon(machine: machineID),
              let tab = daemon.store.tab(idOrResource: id), let pane = daemon.store.pane(holding: tab) else { return nil }
        return (tab, pane)
    }

    /// Finds this very model, not a same-id tab on another machine. A model removed
    /// from its store (including a disconnected machine) has no current pane.
    func locateTab(model tab: TabModel) -> (TabModel, PaneModel)? {
        for daemon in machines.daemons {
            guard daemon.store.tab(idOrResource: tab.id) === tab,
                  let pane = daemon.store.pane(holding: tab) else { continue }
            return (tab, pane)
        }
        return nil
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

    /// A quit deadline's end: it names and records the state files still saving (a paired-phones save is
    /// marked, and the next launch clears its seal), then ends the process (`AgentPaneStateLoss`).
    func quitDeadlineEnd() -> @Sendable () -> Void {
        agentPaneStateLoss.deadlineEnd(files: agentPaneStateFiles, alsoCutOff: { [watch = iphone.pairedQuitWatch] in watch.markCutOffIfSaving() })
    }

    /// The quit's state-file saves (the agent panes' drafts and scroll places, the paired phones' list),
    /// awaited together holding no thread and with no limit of their own: the quit awaits them after its
    /// deadline is armed, and that deadline records what was still saving (``quitDeadlineEnd()``).
    func stateFilesDrained() async {
        let files = agentPaneStateFiles
        async let panes: Void = files.drained()
        await iphone.pairedSavesDrained()
        await panes
    }
}

// Composition of the paid-plan path (plans/cmux-next/paid-plans-DESIGN.md §2); the logic is in CmuxNextAccounts/Billing.
extension AppServices {
    /// The upgrade path every paywall takes: cmux.com Checkout as the signed-in account, returning to this build.
    func paidPlanUpgrade() -> PaidPlanUpgrade {
        let client = cloud.isSignedIn ? accounts.client : nil
        return PaidPlanUpgrade(checkout: client.map(PaidPlanUpgrade.cmuxComCheckout), open: { LinkRouter.shared.open($0) },
                               scheme: cloud.configuration.callbackScheme, onboarding: PaidPlanOnboarding(defaults: .standard), pricing: StaticURL.pricing.url)
    }

    /// The welcome card for a plan the Cloud list read (shown once, after an upgrade).
    func paidPlanObserved(_ planID: String?) {
        PaidPlanWelcome(onboarding: PaidPlanOnboarding(defaults: .standard), account: { [weak self] in self?.cloud.auth.user?.id },
                        ask: { [weak self] in await self?.machineAsks.ask($0, detail: $1, symbol: "sparkles", yes: $2, no: $3) ?? false },
                        startCloudWorkspace: { [weak self] in _ = self?.registry.perform("newCloudWorkspace") }).planObserved(planID)
    }

    /// Back in the app while an upgrade waits for its payment: read the plan again (AppDelegate's activation loop).
    func paidPlanReturned() async {
        if PaidPlanOnboarding(defaults: .standard).hasPending { await cloud.refresh() }
    }
}

nonisolated extension ComputerUseScreenStills: ChiefScreenCaptureHost {}
