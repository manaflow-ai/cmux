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
import CmuxNextMetrics
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextTerminal
import CmuxNextTrace
import CmuxNextWakeups
import os
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The App's control-socket wiring (architecture.md 5a): the main-thread
/// watchdog (made and started in `main()`, handed in), the socket server with a display-link frame
/// source for the main-actor work queue, the snapshot publisher, and the
/// App-only debug methods.
@MainActor
final class AppControl {
    /// The launch's watchdog, running since `main()`; its busy windows end on the main deadline
    /// queue `main()` gave it and the scheduler.
    let watchdog: MainThreadWatchdog
    /// The app's crash keys (the action timing names the running action, the hang monitor the hung threads).
    let crashKeys = CrashKeySlots()
    /// The app's main-thread scheduler (built by `AppDelegate`, the composition root).
    let mainWork: MainWorkScheduler
    private let frames: FrameBatcher
    /// `debug.frames` and `debug.damage` share the app's one RenderStats (its hooks are process-wide;
    /// the probes' methods are in AppControl+DebugProbes.swift).
    #if DEBUG || CMUX_BENCH_HOOKS
    let frameProbe: DebugFrameProbe
    let mainCPUProbe = DebugMainCPUProbe()
    #endif
    let damageWindow: RenderDamageWindow
    /// The app's one RenderStats; terminal renderers count their presented frames in it (AppDelegate).
    let renderStats: RenderStats
    let terminalDisplayProbe: DebugTerminalDisplayProbe
    /// `debug.motion`'s Core Animation commit timer (`ca.commit`), owned here, not by a static.
    let motionCommitProbe = MotionCommitProbe()
    #if DEBUG || CMUX_BENCH_HOOKS
    private let keySequencePlayer = DebugKeySequencePlayer() // `debug.key` sequences' player (one at a time), not a static
    let hops = InputTurnHops() // `debug.input hops`; the MainJobGate hook (021) records into `hops.recorder`
    /// `debug.startup`'s report: the launch marks and the first committed frame (kept by AppDelegate). Counters, scheduler
    /// and catalog wait have no producer yet (tasks 007, 012, 092 wire theirs here); their fields read null until then.
    let startupReport = StartupReportRecorder(launch: { DebugTimings.launchMarksNow }, processStartNanos: DebugTimings.processStartUptimeNanos,
                                              counters: { nil }, scheduler: { _ in nil }, actionCatalogMainWaitMs: { nil })
    #endif
    private(set) var service: ControlService?
    private var publisher: ControlSnapshotPublisher?
    private(set) var errorJournal: ErrorJournalService?
    /// Over-budget action runs: the Release report's counters, and the Debug log line per run.
    private(set) var actionBudget: ActionBudgetReporter?
    /// The frames after the person's actions on the key window (`action.missed_frames.cmd_t/n/w`).
    private var commitWindows: ActionCommitWindows?
    /// The task diagnostics mode (`CMUX_NEXT_MAIN_TASK_DIAGNOSTICS=1`): the watchdog records over-budget
    /// tasks with a stack, and the action budget's Debug line names that it sampled them. Read once.
    private let recordsTaskBudgets = MainThreadWatchdog.recordsTaskBudgets(environment: ProcessInfo.processInfo.environment)

    var socketPath: String? { service?.socketPath }

    private let input: any InputObserving  // the app's input tap: input explains CPU use to the busy watchdog
    private var inputSubscription: InputSubscription?
    /// `idle.wakeups.*` (`AppServices.idleWakeups`): the same input ends its idle period at that input.
    weak var idleWakeups: IdleWakeupSampler?

    /// - Parameters:
    ///   - mainWork: The app's one main-thread scheduler: control requests are its automation tasks, and
    ///     the watchdog reads its board.
    ///   - input: The app's input tap.
    ///   - watchdog: The launch's main-thread watchdog, made and started first in `main()` on `mainWork`'s
    ///     deadline queue (``MainWorkScheduler/wakeUps``).
    init(mainWork: MainWorkScheduler, input: any InputObserving, watchdog: MainThreadWatchdog) {
        (self.mainWork, self.input, self.watchdog) = (mainWork, input, watchdog)
        frames = FrameBatcher(owner: "Control.frames", budgeted: .automation, on: mainWork)
        let renderStats = RenderStats(layoutGuard: .shared)
        self.renderStats = renderStats
        let terminalDisplay = DebugTerminalDisplayProbe()
        terminalDisplayProbe = terminalDisplay
        #if DEBUG || CMUX_BENCH_HOOKS
        frameProbe = DebugFrameProbe(render: RenderFrameLog(stats: renderStats))
        #endif
        damageWindow = RenderDamageWindow(stats: renderStats, displayPasses: terminalDisplay,
                                          ghosttyOwners: [String(describing: TerminalSurfaceView.self), "IOSurfaceLayer"])
    }

    /// Connects the running watchdog to the app: the hang-watch scopes, the scheduler's board, the helper
    /// processes and the input. Call first thing in `applicationDidFinishLaunching`.
    func attachWatchdog() {
        // Hang-watch scopes are scanned on the watchdog's thread (overruns: debug.hangs thread_hangs, crash keys, ring).
        watchdog.attach(hangWatch: TraceRuntime.shared.hangWatch, crashKeys: crashKeys, trace: TraceRuntime.shared)
        // Stall records name the scheduled main-thread task they caught; a launch in the task
        // diagnostics mode also records tasks past their class budget, with a stack (debug.hangs
        // over_budget). It perturbs what it measures, so it is off unless asked for.
        watchdog.attach(board: mainWork.budget.board, recordTaskBudgets: recordsTaskBudgets)
        // Input explains CPU use to the busy watchdog (one atomic add per event) and, while the app is inactive,
        // ends an idle-wakeups period at that input.
        inputSubscription = input.observe(types: Self.activityInput) { [weak self] _ in
            ExpectedActivity.shared.note(.input)
            self?.idleWakeups?.inputArrived()
        }
    }

    /// The input that explains CPU use to the busy watchdog and ends an idle period: key-downs, mouse-downs,
    /// left and right drags, scrolls, moves and the magnify and swipe gestures (the old local monitor's mask).
    static let activityInput: InputEventTypes = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
                                                 .rightMouseDragged, .scrollWheel, .mouseMoved, .magnify, .swipe]

    /// Prepares the service (no socket yet) with its core methods: the sync barrier and the oracle
    /// settle. Every other method family is a group of ``launchGroups(_:settings:)``
    /// (below), registered before the service serves.
    func start(registry: ActionRegistry, settings: SettingsController, launch: LaunchIdentity, services: AppServices) throws {
        let service = try ControlService.prepare(registry: registry, settings: settings, launch: launch,
                                                 frameSource: frames, watchdog: watchdog, mainWork: mainWork,
                                                 hangs: TraceRuntime.shared.hangWatch)
        self.service = service
        AppMemoryConsumers(services: services).registerControlCaches(service)
        actionBudget = ActionBudgetReporter(monitor: services.actionBudget, naming: ActionReportNaming(catalog: Set(registry.descriptors.map(\.id.rawValue))),
                                            overBudget: watchdog.overBudget, sampling: recordsTaskBudgets,
                                            logsRuns: ControlService.isDebugBuild, work: services.work, mainWork: mainWork)
        commitWindows = ActionCommitWindows(monitor: services.actionBudget) { NSApp.keyWindow.map { FrameScheduler.forWindow($0) } }
        services.restartControlListener = { [weak service] in try service?.restartListener() }
        // A busy renderer's record names the Chromium tabs it serves, from the snapshot
        // the cache publishes: the watchdog reads it off the main thread.
        watchdog.busy.setTabSource { [directory = services.cache.tabRenderers] in directory.snapshot() }
        // Its helpers are the children of the Chromium helpers' parent (the app, or the Chromium Host in host mode),
        // read on the watchdog's thread.
        watchdog.busy.setHelperSource { [parent = services.cache.chromium.source.helperParent] in
            AppProcesses.chromiumHelpers(helperParent: parent.pid)
        }
        registerSyncBarrier(service.router, daemon: services.daemon)
    }

    /// The error journal (`cmux errors`): app log, page consoles, acpmux, Chief, crash reports.
    func startErrorJournal(_ services: AppServices, on router: ControlRouter) {
        let errors = ErrorJournalService.make(environment: services.environment, energy: services.mainWork.energy)
        errors.start()
        errorJournal = errors
        router.register(ErrorJournalControl(journal: errors.journal, sources: errors.sources).methods)
    }

    /// Resources, extensions, Ghostty diagnostics, `features.list`, `energy.status`, `metrics.snapshot` and `debug.memory` (release builds too).
    func registerResourceMethods(_ services: AppServices, on router: ControlRouter) {
        router.register([
            // CPU and memory per tab and workspace, two samples `interval_ms` apart.
            .async("resources") { [weak services] call in
                try await ResourceControl.run(call.params, services: services)
            }.withDeadline(.fixed(ResourceControl.deadline)),
            // Installed Chrome extensions, shortcuts and toolbar badges.
            .mainActor("browser.extensions") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(ExtensionControl.report(services))
            },
            // Ghostty config keys and keybind actions cmux does not apply (R92).
            GhosttyDiagnosticsControl().method,
            // Every feature's value and source (`cmux settings feature-flags`), read-only.
            FeatureFlagsPage.report(services.features, tunables: TunableStore.shared,
                                    daemon: services.environment.daemonFeatureHello).method,
            // Energy Saver's policy and inputs (`cmux energy status`, MCP `energy_status`).
            EnergyReport.statusMethod(services: services),
            // The field histograms since launch (`cmux metrics`), read-only; `unavailable` until the metricsView feature is on.
            ControlRouter.metricsMethod(enabled: services.features.isEnabled(.metricsView)),
        ])
        router.register(DebugHibernationControl.methods(services)) // debug.memory and debug.discards serve release builds too
        // trace.start, trace.stop and trace.status (p09-observability 020), behind the default-off traceControl feature.
        if services.features.isEnabled(.traceControl) { router.register(services.daemon.traceMethods(blackBox: services.traceBlackBox?.blackBox, work: services.work)) }
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
        // `latency`: the app tracker's closed slots, per kind and target (first-seconds-lag.md step 3; it was absent).
        let latency = InputLatencyDebugSource(reporter: InputLatencyReporter(), tracker: services.inputLatency.tracker, mainWork: services.mainWork)
        latency.follow { (NSApp.keyWindow?.screen ?? NSScreen.main).map { UInt64(1_000_000_000 / max($0.maximumFramesPerSecond, 1)) } ?? 0 }
        services.work.task(.bestEffort) { await latency.foldBatches() }
        router.register([DebugInput(sources: [latency, InputTapDebugSource(tap: services.inputTap, mainWork: services.mainWork), DebugCEF.pumpInputSource(services.cache.chromium),
                                               DebugCEF.histogramSource(services.cache.chromium),
                                               IntentPrewarmDebugSource { [weak services] in services?.cache.hibernation?.intentPrewarm?.service },
                                               MainJobGateDebugSource { (NSApp as? CmuxApplication)?.jobGate?.gate },
                                               ScrollViewAuditSource { [mainWork = services.mainWork] in
                                                   // A job the scheduler dropped audits nothing.
                                                   (try? await withOnceContinuation { (continuation: OnceContinuation<DebugInputScrollViews, OnceContinuationError>) in
                                                       mainWork.postFromAnyThread(.automation, owner: "debug.input.scroll_views") {
                                                           continuation.resume(returning: DebugInputScrollViews(auditing: NSApp.windows))
                                                       }
                                                   }) ?? DebugInputScrollViews(rows: [])
                                               }],
                                     // `hittest`: one audit for the app, its hooks installed on request only.
                                     recorders: [hops.start(input: input),
                                                 InputDirtyRecorder(tap: services.inputTap) { [mainWork = services.mainWork] copy in
                                                     await mainWork.apply(.automation, owner: "debug.input.dirty") { copy() }
                                                 },
                                                 HitTestAuditDebugRecorder(audit: HitTestAudit(input: services.inputTap)),
                                                 InputLatencySlotsRecorder(tracker: services.inputLatency.tracker, mainWork: services.mainWork)]).method])
        router.register(DebugWindowsControl.methods(services) + [services.daemon.debugControlMethod { [weak services] in services?.windows.controllers.map { (id: $0.state.id, shows: $0.recoveryShows) } ?? [] }, services.daemon.debugDrainCostMethod])
    }
    #endif

    func stop() {
        publisher?.stop()
        service?.stop()
    }
}

/// The control service's method groups: every method family the service registers
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
                // The person's banner click: the answer awaits the requests' actor off main; its reveal is main work.
                services.notifications.onPasskeyBanner = { [work = services.work] id in
                    _ = work.task(.userBlocking) { _ = try? await passkeys.answer(id) }
                }
                // Read per agent click: the agent's work, in the automation class.
                BrowserPageService(engine: AppBrowserPageEngine(services: services), passkeys: passkeys,
                                   agentMouse: { [weak settings, work = services.mainWork] in
                                       await work.apply(.automation, owner: "browser.agent_mouse") {
                                           settings?.snapshot.browserAgentMouse
                                       } ?? AgentMouseSetting().fallback
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
    /// The Chromium host app prototype (feature cefHelperHost; cef-helper-app-DESIGN.md).
    /// Socket focus policy: `open` makes the page first responder only with focus: true.
    private static func registerChromiumHostDebug(_ services: AppServices, on router: ControlRouter) {
        let hostSwitch = chromiumHostSwitch(in: services.features, tunables: TunableStore.shared)
        let chromiumHost = ChromiumHostPrototype(makeConfiguration: { ChromiumHostPrototype.bundledConfiguration() },
                                                 isOn: { hostSwitch.isEnabled }, mainWork: services.mainWork,
                                                 deadlines: services.mainDeadlines,
                                                 idleExitAfter: chromiumHostIdleExit(in: services.features),
                                                 inputPresented: { [weak services] in _ = services?.inputLatency.tracker.hostPresented(eventNanos: $0, at: $1) },
                                                 reportsInputPresented: { [weak services] in services?.inputLatency.tracker.pagesReportPresentation = $0 })
        router.register([
            .mainActor("debug.chromium_host") { [weak services] call in
                let controller = services?.windows.controllers.first
                let pane = (call.params["pane"]?.stringValue ?? controller?.focus.state.pane).flatMap { controller?.content?.paneController(key: $0) }
                var fields = chromiumHost.handle(op: call.params["op"]?.stringValue, url: call.params["url"]?.stringValue,
                                                 over: pane?.view.contentHost, focus: call.params["focus"]?.boolValue == true,
                                                 idleExitSeconds: call.params["idle_exit_s"]?.doubleValue)
                // Host mode's input route (feature chromiumHostInputRing), without building the engine.
                if let route = services?.cache.chromium.built?.hostInputReport { fields["input_route"] = route }
                return .value(JSONValue(foundation: fields) ?? .null)
            },
            .async("debug.chromium_host.measure") { call in
                guard let fields = await chromiumHost.measure(op: call.params["op"]?.stringValue, count: call.params["count"]?.intValue)
                else { return ["error": "no running Chromium host"] }
                return .object(fields.mapValues(JSONValue.number))
            }.withDeadline(.fixed(.seconds(60))),
        ])
    }

    /// The Chromium host's idle deadline: `chromiumHostIdleExit`'s `idleExitAfter` while the
    /// feature is on, else nil (the host runs while its session does).
    static func chromiumHostIdleExit(in features: FeatureList) -> Duration? {
        guard features.isEnabled(.chromiumHostIdleExit) else { return nil }
        for param in Feature.chromiumHostIdleExit.params where param.name == "idleExitAfter" {
            if case .duration(let seconds, _, _) = param.value { return .seconds(seconds) }
        }
        return nil
    }

    /// The Chromium host's switch: the launch's `cefHelperHost`, which Debug Settings
    /// `browserHost.helper` overrides in FeatureList's order: below policy and the
    /// environment, above remote, trial and the channel default, never in Release.
    static func chromiumHostSwitch(in features: FeatureList, tunables: TunableStore) -> BrowserHostSwitch {
        let launch = features.resolution(of: .cefHelperHost)
        let decidedAboveLocal = launch.source == .policy || launch.source == .environment
        return BrowserHostSwitch(launchValue: launch.isEnabled,
                                 takesLocalOverride: features.channel.allowsLocalOverrides && !decidedAboveLocal, tunables: tunables)
    }
    #endif
}

/// The control socket's launch order (plans/cmux-next/chrome-parity/p08-startup.md 3A).
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
                           groups: launchGroups(services, settings: settings), served: launchServed(logger: logger))
    }

    /// Without the feature (nil `socket`), once the launch settled: starts the service, registers every
    /// group and binds, now. With it: nothing (``postLaunch(socket:order:services:settings:launch:logger:)`` did).
    func runAfterSettle(socket: ControlSocketBind?, services: AppServices, settings: SettingsController, launch: LaunchIdentity,
                        logger: Logger) {
        guard socket == nil else { return }
        ControlLaunch.run(start: launchStart(services, settings: settings, launch: launch), groups: launchGroups(services, settings: settings),
                          served: launchServed(logger: logger))
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

    /// The socket serves, or why it does not. (Share This Mac resumes in its own afterStartup post, p08-startup-029.)
    private func launchServed(logger: Logger) -> @MainActor @Sendable (Result<String, any Error>) -> Void {
        { result in
            switch result {
            case .success(let path):
                DebugTimings.markLaunch("control.serving")
                logger.info("control socket \(path, privacy: .public)")
            case .failure(let error):
                logger.error("control socket failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
