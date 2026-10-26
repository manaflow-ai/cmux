import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextEnergy
import CmuxNextErrorJournal
import CmuxNextFeatures
import CmuxNextInput
import CmuxNextInputDiagnostics
import CmuxNextLaunch
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextTerminal
import CmuxNextTrace
import CmuxNextWakeups
import os

/// The App's control-socket wiring (architecture.md 5a): the main-thread
/// watchdog (from launch), the socket server with a display-link frame
/// source for the main-actor work queue, the snapshot publisher, and the
/// App-only debug methods.
@MainActor
final class AppControl {
    /// The watchdog, and the app's crash keys (p10-stability-207: the action timing names the running action, the hang monitor the hung threads).
    let watchdog = MainThreadWatchdog(), crashKeys = CrashKeySlots()
    /// The app's main-thread scheduler (built by `AppDelegate`, the composition root).
    let mainWork: MainWorkScheduler
    private let frames: FrameBatcher
    /// `debug.frames` and `debug.damage` share the app's one RenderStats (its hooks are process-wide;
    /// the probes' methods are in AppControl+DebugProbes.swift).
    let frameProbe: DebugFrameProbe
    let damageWindow: RenderDamageWindow
    let mainCPUProbe = DebugMainCPUProbe()
    let terminalDisplayProbe: DebugTerminalDisplayProbe
    /// `debug.motion`'s Core Animation commit timer (`ca.commit`), owned here, not by a static.
    let motionCommitProbe = MotionCommitProbe()
    #if DEBUG || CMUX_BENCH_HOOKS
    /// `debug.key` sequences' player (one sequence at a time), owned here, not by a static.
    private let keySequencePlayer = DebugKeySequencePlayer()
    #endif
    private(set) var service: ControlService?
    private var publisher: ControlSnapshotPublisher?
    private(set) var errorJournal: ErrorJournalService?
    /// Over-budget action runs: the Release report's counters, and the Debug log line per run.
    private(set) var actionBudget: ActionBudgetReporter?
    /// The task diagnostics mode (`CMUX_NEXT_MAIN_TASK_DIAGNOSTICS=1`): the watchdog records over-budget
    /// tasks with a stack, and the action budget's Debug line names that it sampled them. Read once.
    private let recordsTaskBudgets = MainThreadWatchdog.recordsTaskBudgets(environment: ProcessInfo.processInfo.environment)

    var socketPath: String? { service?.socketPath }

    private let input: any InputObserving  // the app's input tap: input explains CPU use to the busy watchdog
    private var inputSubscription: InputSubscription?

    /// - Parameter mainWork: The app's one main-thread scheduler: control requests are its
    ///   automation tasks, and the watchdog reads its board. `input` is the app's input tap.
    init(mainWork: MainWorkScheduler, input: any InputObserving) {
        (self.mainWork, self.input) = (mainWork, input)
        frames = FrameBatcher(owner: "Control.frames", budgeted: .automation, on: mainWork)
        let renderStats = RenderStats(layoutGuard: .shared)
        let terminalDisplay = DebugTerminalDisplayProbe()
        terminalDisplayProbe = terminalDisplay
        frameProbe = DebugFrameProbe(render: RenderFrameLog(stats: renderStats))
        damageWindow = RenderDamageWindow(stats: renderStats, displayPasses: terminalDisplay,
                                          ghosttyOwners: [String(describing: TerminalSurfaceView.self), "IOSurfaceLayer"])
    }

    /// Starts stall and busy detection. Call first thing at launch.
    func startWatchdog() {
        watchdog.start()
        // Hang-watch scopes are scanned on the watchdog's thread (overruns: debug.hangs thread_hangs, crash keys).
        watchdog.attach(hangWatch: TraceRuntime.shared.hangWatch, crashKeys: crashKeys)
        // Stall records name the scheduled main-thread task they caught; a launch in the task
        // diagnostics mode also records tasks past their class budget, with a stack (debug.hangs
        // over_budget). It perturbs what it measures, so it is off unless asked for.
        watchdog.attach(board: mainWork.budget.board, recordTaskBudgets: recordsTaskBudgets)
        watchdog.busy.setHelperSource { AppProcesses.chromiumHelpers() }
        // Input explains CPU use to the busy watchdog (one atomic add per event).
        inputSubscription = input.observe(types: Self.activityInput) { _ in ExpectedActivity.shared.note(.input) }
    }

    /// The input that explains CPU use to the busy watchdog: key-downs, mouse-downs, left and right
    /// drags, scrolls, moves and the magnify and swipe gestures (the old local monitor's mask).
    static let activityInput: InputEventTypes = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
                                                 .rightMouseDragged, .scrollWheel, .mouseMoved, .magnify, .swipe]

    /// Prepares the service (no socket yet) with its core methods: the sync barrier and the oracle
    /// settle. Every other method family is a group of ``launchGroups(_:settings:)``
    /// (below), registered before the service serves (p08-startup-019).
    func start(registry: ActionRegistry, settings: SettingsController, launch: LaunchIdentity, services: AppServices) throws {
        let service = try ControlService.prepare(registry: registry, settings: settings, launch: launch,
                                                 frameSource: frames, watchdog: watchdog, mainWork: mainWork)
        self.service = service
        actionBudget = ActionBudgetReporter(monitor: services.actionBudget, naming: ActionReportNaming(catalog: Set(registry.descriptors.map(\.id.rawValue))),
                                            overBudget: watchdog.overBudget, sampling: recordsTaskBudgets,
                                            logsRuns: ControlService.isDebugBuild)
        services.restartControlListener = { [weak service] in try service?.restartListener() }
        registerSyncBarrier(service.router, daemon: services.daemon)
        registerOracleSettle(service.router, services: services)
    }

    /// The error journal (`cmux errors`): app log, page consoles, acpmux, Chief, crash reports.
    func startErrorJournal(_ services: AppServices, on router: ControlRouter) {
        let errors = ErrorJournalService.make(environment: services.environment)
        errors.start()
        errorJournal = errors
        router.register(ErrorJournalControl(journal: errors.journal, sources: errors.sources).methods)
    }

    /// Resources, extensions, Ghostty diagnostics and `debug.memory` (release builds too).
    func registerResourceMethods(_ services: AppServices, on router: ControlRouter) {
        router.register([
            // CPU and memory per tab and workspace, two samples `interval_ms` apart.
            .async("resources") { [weak services] call in
                let services = await MainActor.run { services }
                return try await ResourceControl.run(call.params, services: services)
            }.withDeadline(.fixed(ResourceControl.deadline)),
            // Installed Chrome extensions, shortcuts and toolbar badges.
            .mainActor("browser.extensions") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(ExtensionControl.report(services))
            },
            // Ghostty config keys and keybind actions cmux does not apply (R92).
            GhosttyDiagnosticsControl().method,
        ])
        router.register(DebugHibernationControl.methods(services)) // debug.memory serves release builds too
    }

    func startSnapshotPublisher(_ services: AppServices, on router: ControlRouter) {
        let publisher = ControlSnapshotPublisher(router: router, services: services)
        self.publisher = publisher
        publisher.start()
    }

    // Other diagnostics are for tagged DEV builds: release registers no other debug.* (Configuration.allowsDebugMethods).
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The newest action runs and the over-budget counters (zero-latency.md, the budget contract), the
    /// daemon wire, the input tap and the windows.
    func registerDebugBudgetMethods(_ services: AppServices, on router: ControlRouter) {
        if let actionBudget { router.register([actionBudget.method(registry: services.registry)]) }
        // The local daemon's wire traffic, decodes, output copies and connections by role.
        if let wireStats = services.wireStats { router.register([DaemonWireControl(stats: wireStats).method]) }
        router.register([DebugInput(sources: [InputTapDebugSource(tap: services.inputTap), DebugCEF.pumpInputSource(services.cache.chromium)]).method])
        router.register(DebugWindowsControl.methods(services) + [services.daemon.debugControlMethod { [weak services] in services?.windows.controllers.map { (id: $0.state.id, shows: $0.recoveryShows) } ?? [] }, services.daemon.debugDrainCostMethod])
    }
    #endif

    func stop() {
        publisher?.stop()
        service?.stop()
    }
}

/// The control service's method groups (p08-startup-019): every method family the service registers
/// after its core start (``AppControl/start(registry:settings:launch:services:)``), one group each, in
/// the order they registered in before. With the feature `controlSocketEarlyBind` each group is its
/// own afterFirstFrame post (`ControlLaunch`), budgeted behind input, so no single main turn after the
/// first frame registers them all; the service accepts only after the last one.
extension AppControl {
    /// The groups, in registration order; the snapshot publisher's start among them.
    ///
    /// - Parameters:
    ///   - services: The app's services (held weakly: a group of an app that is going does nothing).
    ///   - settings: The settings the browser page service reads the agent mouse from (held weakly).
    func launchGroups(_ services: AppServices, settings: SettingsController) -> [ControlLaunch.Group] {
        var groups: [ControlLaunch.Group] = [
            group("Control.registerHistory", services) { _, services, router in router.register(HistoryControl.methods(services: services)) },
            group("Control.registerTabSearch", services) { _, _, router in router.register(TabSearchControl.methods()) },
            group("Control.registerPaletteScope", services) { _, services, router in
                router.register(PaletteScopeControl.methods(services: services, router: router))
            },
            group("Control.registerBookmarks", services) { _, services, router in router.register(BookmarkControl.methods(services: services)) },
            group("Control.registerFeed", services) { _, services, router in router.register(FeedControl.methods(services: services)) },
            group("Control.registerServerReach", services) { _, services, router in router.register(ServerReachControl.methods(services: services)) },
            group("Control.registerKeybindings", services) { _, services, router in router.register(KeybindingControl.methods(services: services)) },
            group("Control.registerSettings", services) { _, services, router in router.register(SettingsControl.methods(services: services)) },
            group("Control.registerTerminalLinkOpen", services) { _, services, router in
                router.register(TerminalLinkOpenControl.methods(services: services))
            },
            group("Control.registerPermissions", services) { _, services, router in router.register(PermissionsControl.methods(services: services)) },
            group("Control.registerNotifications", services) { _, services, router in
                router.register(NotificationsControl.methods(services: services))
            },
            group("Control.registerSessionTransfer", services) { _, services, router in
                router.register(SessionTransferControl.methods(services: services))
            },
            group("Control.startErrorJournal", services) { control, services, router in control.startErrorJournal(services, on: router) },
            group("Control.registerResources", services) { control, services, router in control.registerResourceMethods(services, on: router) },
        ]
        #if DEBUG || CMUX_BENCH_HOOKS
        groups += [
            group("Control.registerDebugBudget", services) { control, services, router in control.registerDebugBudgetMethods(services, on: router) },
            group("Control.registerDebugProbes", services) { control, services, router in control.registerDebugProbeMethods(services, on: router) },
            group("Control.registerDebugDrivers", services) { control, services, router in
                DebugDriverControl.register(on: router, services: services, keys: control.keySequencePlayer)
            },
        ]
        #endif
        groups += [
            group("Control.startSnapshotPublisher", services) { control, services, router in control.startSnapshotPublisher(services, on: router) },
            group("Control.registerCloud", services) { control, services, _ in control.registerCloudMethods(services) },
            group("Control.registerAccounts", services) { control, services, _ in control.registerAccountsMethods(services) },
            group("Control.registerBilling", services) { control, services, _ in control.registerBillingMethods(services) },
            group("Control.registerRemote", services) { control, services, _ in control.registerRemoteMethods(services) },
            group("Control.registerMobile", services) { control, services, _ in control.registerMobileMethods(services) },
            group("Control.registerUpdates", services) { control, services, _ in control.registerUpdateMethods(services.updater, services: services) },
            group("Control.registerInput", services) { control, services, _ in control.registerInputMethods(services) },
            group("Control.registerSettingsDebug", services) { control, services, _ in control.registerSettingsDebugMethods(services) },
            group("Control.registerPageDebug", services) { control, services, _ in control.registerPageDebugMethods(services) },
            group("Control.registerRemoteBrowserDebug", services) { control, services, _ in control.registerRemoteBrowserDebugMethods(services) },
            group("Control.registerRemoteViewDebug", services) { _, services, router in RemoteViewDebugMethods(services: services).register(on: router) },
            group("Control.registerMacScreenDebug", services) { _, services, router in services.registerMacScreenDebug(on: router) },
            group("Control.registerDeviceHubDebug", services) { _, services, router in services.registerDeviceHubDebug(on: router) },
            group("Control.registerNowPlayingDebug", services) { _, services, router in DebugNowPlaying.register(on: router, services: services) },
            group("Control.registerDownloadsDebug", services) { _, services, router in DebugDownloads.register(on: router, services: services) },
            group("Control.registerCEFDevToolsLayoutDebug", services) { _, services, router in
                DebugCEFDevToolsLayout.register(on: router, services: services)
            },
        ]
        #if DEBUG || CMUX_BENCH_HOOKS
        groups.append(group("Control.registerChromiumHostDebug", services) { _, services, router in Self.registerChromiumHostDebug(services, on: router) })
        #endif
        groups += [
            group("Control.registerBrowserExternalDebug", services) { _, services, router in DebugBrowserExternal.register(on: router, services: services) },
            group("Control.registerCloudMoveDebug", services) { _, services, router in DebugCloudMove.register(on: router, services: services) },
            group("Control.registerTerminalLinksDebug", services) { _, services, router in DebugTerminalLinks.register(on: router, services: services) },
            group("Control.registerBrowserPage", services) { [weak settings] _, services, router in
                // The passkey hand-off: an agent's request waits for the person's banner click.
                let passkeys = BrowserPasskeyRequests(host: AppBrowserPasskeyHost(services: services))
                services.notifications.onPasskeyBanner = { id in Task { _ = try? await passkeys.answer(id) } }
                BrowserPageService(engine: AppBrowserPageEngine(services: services), passkeys: passkeys,
                                   agentMouse: { [weak settings] in
                                       await MainActor.run { settings?.snapshot.browserAgentMouse } ?? AgentMouseSetting().fallback
                                   }).install(on: router)
                services.apps.attach(router: router)
            },
        ]
        return groups
    }

    /// One group: runs `register` with this control, the services and the router while both are alive.
    private func group(_ name: StaticString, _ services: AppServices,
                       _ register: @escaping @MainActor @Sendable (AppControl, AppServices, ControlRouter) -> Void) -> ControlLaunch.Group {
        ControlLaunch.Group(name) { [weak self, weak services] router in
            guard let self, let services else { return }
            register(self, services, router)
        }
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The Chromium host app prototype (browserHost.helper; cef-helper-app-DESIGN.md).
    /// Socket focus policy: `open` makes the page first responder only with focus: true.
    private static func registerChromiumHostDebug(_ services: AppServices, on router: ControlRouter) {
        let chromiumHost = ChromiumHostPrototype(makeConfiguration: { ChromiumHostPrototype.bundledConfiguration() },
                                                 tunables: TunableStore.shared, mainWork: services.mainWork)
        router.register([
            .mainActor("debug.chromium_host") { [weak services] call in
                let controller = services?.windows.controllers.first
                let pane = (call.params["pane"]?.stringValue ?? controller?.focus.state.pane).flatMap { controller?.content?.paneController(key: $0) }
                let fields = chromiumHost.handle(op: call.params["op"]?.stringValue, url: call.params["url"]?.stringValue,
                                                 over: pane?.view.contentHost, focus: call.params["focus"]?.boolValue == true)
                return .value(JSONValue(foundation: fields) ?? .null)
            },
            .async("debug.chromium_host.measure") { call in
                guard let fields = await chromiumHost.measure(op: call.params["op"]?.stringValue, count: call.params["count"]?.intValue)
                else { return ["error": "no running Chromium host"] }
                return .object(fields.mapValues(JSONValue.number))
            }.withDeadline(.fixed(.seconds(60))),
        ])
    }
    #endif
}

/// The control socket's launch order (p08-startup-019, plans/cmux-next/chrome-parity/p08-startup.md 3A).
///
/// With the feature `controlSocketEarlyBind` (default off, risk:high):
/// - ``beginBind(features:settingsRead:launch:work:mainWork:)``, right after the settings launch read:
///   the bind (state folder, owner lock, stale-socket check, bind, listen, compatibility link) runs on a
///   lane with the access mode that read resolves (`CMUX_NEXT_SOCKET_MODE`, else cmux.json with its
///   managed layers). A mode of `off` binds nothing, as before.
/// - ``postLaunch(socket:order:services:settings:launch:logger:)``: the service's core start, each
///   method group (``launchGroups(_:settings:)``) and the start of accepting are afterFirstFrame posts
///   (`ControlLaunch`). A launch with no first frame by its reveal (hidden, no window, the 1.5 s reveal
///   deadline) releases them at the reveal (`ControlLaunch.releaseAtReveal`), so automation never waits
///   for the 10 s failsafe.
///
/// Without it, the cx-z9kz0 order (d08d8d7d3c5): the app awaits the first settings load and the launch
/// settle (at most 4 s) and runs the legacy settings migrations, then
/// ``runAfterSettle(socket:services:settings:launch:logger:)`` starts the service, registers every group
/// and binds, in one turn. The migrations keep that place with the feature on (none of them is the
/// socket mode).
extension AppControl {
    /// Begins the bind on a lane when `controlSocketEarlyBind` is on; nil when it is off (the service
    /// binds when it starts).
    static func beginBind(features: FeatureList, settingsRead: SettingsController.LaunchRead, launch: LaunchIdentity,
                          work: BackgroundWork, mainWork: MainWorkScheduler) -> ControlSocketBind? {
        guard features.isEnabled(.controlSocketEarlyBind) else { return nil }
        let configured = settingsRead.snapshot.root.value(at: ["automation", "socketControlMode"])?.stringValue
        return ControlSocketBind.begin(launch: launch, environment: ProcessInfo.processInfo.environment, configured: configured,
                                       work: work, mainWork: mainWork)
    }

    /// With the feature (a `socket` from ``beginBind(features:settingsRead:launch:work:mainWork:)``):
    /// posts the launch's control posts. Without it (nil): nothing.
    func postLaunch(socket: ControlSocketBind?, order: LaunchOrder, services: AppServices, settings: SettingsController,
                    launch: LaunchIdentity, logger: Logger) {
        guard let socket else { return }
        ControlLaunch.releaseAtReveal(phase: order.mainWork.startup, startup: order.startup)
        ControlLaunch.post(on: order.startup, socket: socket, start: launchStart(services, settings: settings, launch: launch),
                           groups: launchGroups(services, settings: settings), served: launchServed(services, logger: logger))
    }

    /// Without the feature (nil `socket`), once the launch settled: starts the service, registers every
    /// group and binds, now. With it: nothing (``postLaunch(socket:order:services:settings:launch:logger:)`` did).
    func runAfterSettle(socket: ControlSocketBind?, services: AppServices, settings: SettingsController, launch: LaunchIdentity,
                        logger: Logger) {
        guard socket == nil else { return }
        ControlLaunch.run(start: launchStart(services, settings: settings, launch: launch), groups: launchGroups(services, settings: settings),
                          served: launchServed(services, logger: logger))
    }

    /// The service's core start (nil: the app is going).
    private func launchStart(_ services: AppServices, settings: SettingsController,
                             launch: LaunchIdentity) -> @MainActor @Sendable () throws -> ControlService? {
        { [weak self, weak services, weak settings] in
            guard let self, let services, let settings else { return nil }
            try start(registry: services.registry, settings: settings, launch: launch, services: services)
            return service
        }
    }

    /// The socket serves, or why it does not; then Share This Mac resumes when the person left it on.
    private func launchServed(_ services: AppServices, logger: Logger) -> @MainActor @Sendable (Result<String, any Error>) -> Void {
        { [weak services] result in
            switch result {
            case .success(let path):
                DebugTimings.markLaunch("control.serving")
                logger.info("control socket \(path, privacy: .public)")
            case .failure(let error):
                logger.error("control socket failed: \(String(describing: error), privacy: .public)")
            }
            services?.macScreenPages.activate()
        }
    }
}
