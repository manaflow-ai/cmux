import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextBrowserImport
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextErrorJournal
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextTerminal
import CmuxNextWakeups

/// The App's control-socket wiring (architecture.md 5a): the main-thread
/// watchdog (from launch), the socket server with a display-link frame
/// source for the main-actor work queue, the snapshot publisher, and the
/// App-only debug methods.
@MainActor
final class AppControl {
    let watchdog = MainThreadWatchdog()
    /// The app's main-thread scheduler (built by `AppDelegate`, the composition root).
    private let mainWork: MainWorkScheduler
    private let frames: FrameBatcher
    private let frameProbe = DebugFrameProbe()
    private let mainCPUProbe = DebugMainCPUProbe()
    private let terminalDisplayProbe = DebugTerminalDisplayProbe()
    /// `debug.motion`'s Core Animation commit timer (`ca.commit`), owned here, not by a static.
    private let motionCommitProbe = MotionCommitProbe()
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

    private var inputMonitor: Any?

    /// - Parameter mainWork: The app's one main-thread scheduler: control requests are its
    ///   automation tasks, and the watchdog reads its board.
    init(mainWork: MainWorkScheduler) {
        self.mainWork = mainWork
        frames = FrameBatcher(owner: "Control.frames", budgeted: .automation, on: mainWork)
    }

    /// Starts stall and busy detection. Call first thing at launch.
    func startWatchdog() {
        watchdog.start()
        // Stall records name the scheduled main-thread task they caught; a launch in the task
        // diagnostics mode also records tasks past their class budget, with a stack (debug.hangs
        // over_budget). It perturbs what it measures, so it is off unless asked for.
        watchdog.attach(board: mainWork.budget.board, recordTaskBudgets: recordsTaskBudgets)
        watchdog.busy.setHelperSource { AppProcesses.chromiumHelpers() }
        // Input explains CPU use to the busy watchdog (one atomic add per event).
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                                   .leftMouseDragged, .rightMouseDragged, .scrollWheel,
                                                                   .mouseMoved, .magnify, .swipe]) { event in
            ExpectedActivity.shared.note(.input)
            return event
        }
    }

    func start(registry: ActionRegistry, settings: SettingsController, launch: LaunchIdentity, services: AppServices) throws {
        let service = try ControlService.start(registry: registry, settings: settings, launch: launch,
                                               frameSource: frames, watchdog: watchdog)
        self.service = service
        let budget = ActionBudgetReporter(monitor: services.actionBudget, naming: ActionReportNaming(catalog: Set(registry.descriptors.map(\.id.rawValue))),
                                          overBudget: watchdog.overBudget, sampling: recordsTaskBudgets,
                                          logsRuns: ControlService.isDebugBuild)
        actionBudget = budget
        services.restartControlListener = { [weak service] in try service?.restartListener() }
        registerSyncBarrier(service.router, daemon: services.daemon)
        service.router.register(HistoryControl.methods(services: services))
        service.router.register(TabSearchControl.methods())
        service.router.register(PaletteScopeControl.methods(services: services, router: service.router))
        service.router.register(BookmarkControl.methods(services: services))
        service.router.register(FeedControl.methods(services: services))
        service.router.register(ServerReachControl.methods(services: services))
        service.router.register(KeybindingControl.methods(services: services))
        // `video.frames`: a video's numbers and frames for the agent tools `video_info` and `video_frames`.
        service.router.register(VideoControl().methods())
        // `agent.acpmux`: the acpmux this app's chat tabs use (`cmux agents chat new`, #23026).
        let build = services.environment.build
        service.router.register([.agentAcpmux {
            let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
            return AcpmuxEnvironment.resolve(build: build, bundledBinDirectory: bin, environment: ProcessInfo.processInfo.environment)
                .map { ($0.socketPath, $0.home.path) }
        }])
        service.router.register(SettingsControl.methods(services: services))
        service.router.register(TerminalLinkOpenControl.methods(services: services))
        service.router.register(PermissionsControl.methods(services: services))
        service.router.register(NotificationsControl.methods(services: services))
        service.router.register(SessionTransferControl.methods(services: services))
        // The error journal (`cmux errors`): app log, page consoles, acpmux, Chief, crash reports.
        let errors = ErrorJournalService.make(environment: services.environment)
        errors.start()
        errorJournal = errors
        services.errorJournal = errors
        service.router.register(ErrorJournalControl(journal: errors.journal, sources: errors.sources).methods)
        service.router.register([
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
        // Diagnostics for tagged DEV builds; a release build registers no debug.* method
        // (ControlRouter drops them too: Configuration.allowsDebugMethods).
        #if DEBUG || CMUX_BENCH_HOOKS
        // The newest action runs and the over-budget counters (zero-latency.md, the budget contract).
        service.router.register([budget.method(registry: registry)])
        service.router.register(DebugHibernationControl.methods(services))
        service.router.register(DebugWindowsControl.methods(services) + [services.daemon.debugControlMethod { [weak services] in services?.windows.controllers.map { (id: $0.state.id, shows: $0.recoveryShows) } ?? [] }, services.daemon.debugRequestLatencyMethod()])
        service.router.register([
            .mainActor("debug.frames") { [probe = frameProbe] call in .value(probe.handle(call.params)) },
            // Main-thread blocking call sites since launch (threading-model.md); {"reset": true} zeroes the counts.
            BlockingControl(detector: services.blocking).method,
            // The main-thread scheduler's per-frame budget: tasks, input yields, deferrals, longest task per class.
            .mainActor("debug.main_budget") { [budget = mainWork.budget] call in
                let report = budget.report
                if call.params["reset"]?.boolValue == true { budget.resetStats() }
                return .value(report)
            },
            // Main-thread CPU per frame against a 120 Hz frame (anim-perf-terminal.py).
            .mainActor("debug.main_cpu") { [probe = mainCPUProbe] call in .value(probe.handle(call.params)) },
            // Main-thread time in Ghostty's display passes (bench-terminal-resize.py).
            .mainActor("debug.terminal_display") { [probe = terminalDisplayProbe] call in .value(probe.handle(call.params)) },
            // Measured animation spans (plans/cmux-next/motion.md).
            .mainActor("debug.motion") { [weak services, probe = motionCommitProbe] call in
                .value(DebugMotion.handle(call.params, services, commitProbe: probe))
            },
            // Launch, palette-open and terminal-creation spans (bench-stalls.py).
            .mainActor("debug.timings") { call in .value(DebugTimings.handle(call.params)) },
            // Each tab switch's own time: intent to shown, and to the next frame (perf-gate.py).
            .mainActor("debug.tab_switch") { call in .value(DebugTabSwitch.timer.handle(call.params, key: "switches")) },
            // Each pane focus move's own time: intent to settled, and to the next frame (perf-gate.py pane_focus).
            .mainActor("debug.pane_focus") { call in .value(DebugPaneFocus.handle(call.params)) },
            // Each workspace switch's own time: input to shown content, and to its commit (perf-budgets.py).
            .mainActor("debug.workspace_switch") { call in .value(DebugWorkspaceSwitch.timer.handle(call.params, key: "switches")) },
            // Each new workspace's own time: the press to its sidebar row drawn, and the walks between (perf-gate.py).
            .mainActor("debug.new_workspace") { call in .value(SidebarNewRowTimer.shared.timer.handle(call.params, key: "creates")) },
            // Work per layout change: pane snapshots, applies, topology sends (bench_pane_scale.py).
            .mainActor("debug.layout_counters") { call in .value(DebugLayoutCounters.handle(call.params)) },
            // A full-screen or Space transition: notifications, resizes, layout passes (fullscreen-transition.py).
            .mainActor("debug.window_transition") { call in .value(DebugWindowTransition.shared.handle(call.params)) },
            // A split's or close's terminals: grids sent, drawn and announced, ms from start (bench-terminal-resize.py split-resize).
            .mainActor("debug.terminal_final_grid") { [weak services] call in
                guard let trace = services?.finalGridTrace else { return .value(.null) }
                if call.params["action"]?.stringValue == "start" { trace.start(); return .value(["started": true]) }
                func marks(_ list: [TerminalFinalGridTrace.Mark]) -> CmuxNextSettings.JSONValue { .array(list.map { ["ms": .number($0.ms), "grid": .string($0.grid)] }) }
                return .value(["terminals": .object(trace.stop().mapValues { terminal in
                    ["sends": marks(terminal.sends), "drawn": marks(terminal.drawn), "owner": marks(terminal.owner),
                     "fitted": terminal.fitted.map(CmuxNextSettings.JSONValue.string) ?? .null]
                })])
            },
            // Sidebar work: rebuilds, row patches/configures, ffi calls (sidebar-rows-perf-live.py).
            .mainActor("debug.sidebar_perf") { call in .value(.object(SidebarView.perfCounters(reset: call.params["reset"]?.boolValue == true).mapValues { .number(Double($0)) })) },
            // Click by Hint labels (hint-mode-e2e.py).
            .mainActor("debug.hints") { [weak services] call in
                guard let services else { return .value(.null) }
                DebugHints.watchMenus()
                return .value(DebugHints.report(services.windowHints, params: call.params))
            },
            .mainActor("debug.page_host_pool") { [weak services] call in
                .value(DebugPageHostPool.handle(call.params, services: services))
            },
            // Focus model vs AppKit vs Ghostty per window (plans/cmux-next/focus.md); `deactivate` backgrounds the app first.
            .mainActor("debug.focus") { [weak services] call in
                guard let services else { return .value(.null) }
                if call.params["deactivate"]?.boolValue == true { NSApp.deactivate(handingActivationTo: call.params["activate_pid"]?.intValue) }
                return .value(DebugFocus.report(services: services))
            },
            // Home per window and the local conversation projection (home.md).
            .mainActor("debug.home") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugHome.report(services: services))
            },
            // My pending and refused sends with the reason (no screenshot needed).
            .mainActor("debug.home.delivery") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugHome.delivery(services: services))
            },
            // Room, workspace and terminal theme scopes.
            .mainActor("debug.themes") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugThemes.report(services: services))
            },
            // Omnibar state machine vs its field editor (focus.md section 7).
            .mainActor("debug.omnibar") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugOmnibar.report(call.params, services: services))
            },
            // Chief hands (cx-om025): levels, presence key, waiting requests; answers HandsService.debug JSON text.
            .mainActor("debug.hands") { [weak services] call in
                guard let hands = services?.cloud.hands else { return .value(.null) }
                return .followUp { [params = call.params.compactMapValues(\.stringValue)] in .string(await hands.debug(params)) }
            },
            // Unread tabs, attention marks, banners and the dismissal log
            // (plans/cmux-next/notifications.md); "click" runs a banner click.
            .mainActor("debug.notifications") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugNotifications.handle(call.params, services: services))
            },
            // App overlays vs content child windows (Chromium pages).
            // `reset_layout_passes: true` clears the layout pass counts first.
            .mainActor("debug.layers") { [weak services] call in
                guard let services else { return .value(.null) }
                if call.params["reset_layout_passes"]?.boolValue == true { LayoutPassGuard.shared.reset() }
                return .value(DebugLayers.report(services: services, params: call.params))
            },
            // The one hover card: machine phase, card window, timer, monitor.
            // `{dismiss: true}` first dismisses the shown card as an app action would (live checks).
            .mainActor("debug.hover_cards") { [weak services] call in
                guard let services else { return .value(.null) }
                if call.params["dismiss"]?.boolValue == true { services.hoverCards.dismiss(.action) }
                // `gallery: sidebar|tabs|none` shows the card kinds over fixture data (HoverCardGallery).
                return .value(.object((HoverCardGallery.show(call.params["gallery"]?.stringValue) ?? services.hoverCards.report).mapValues(JSONValue.string)))
            },
            // Pane chrome alignment: tab pill gaps, border, first terminal cell.
            .mainActor("debug.pane_chrome") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugPaneChrome.report(services: services))
            },
            // Docked columns, the strip range and its scrollbar; `pane` +
            // `dock` changes a column (plans/cmux-next/dock-column.md).
            .mainActor("debug.dock") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugDockColumns.handle(call.params, services: services))
            },
            // Agent cursor visibility per browser tab (`target` narrows it).
            .mainActor("debug.agent_cursor") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugAgentCursor.report(call.params, services: services))
            },
            .mainActor("debug.screens") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugScreens.report(services: services))
            },
            // The action signposts' commit boundary against this macOS's display observers.
            .mainActor("debug.commit_boundary") { _ in .value(DebugCommitBoundary().report()) },
            // Idle wakeups: ledger, display-link clients, process CPU (idle-wakeups.md).
            .async("debug.wakeups") { [budgeted = mainWork.frames, work = services.work] call in
                try await DebugWakeups.report(call.params, budgeted: budgeted, work: work)
            },
            // Chromium start: trigger (tab or warm reason), timings, footprint.
            .mainActor("debug.cef") { [weak services] call in
                guard let services else { return .value(.null) }
                // {"side_panel": "<control>"} runs a side panel header control first.
                if let control = call.params["side_panel"]?.stringValue { DebugCEF.pressSidePanel(control, services: services) }
                // {"drop_spare": true} closes the spare Chromium window (its memory cost, PL-cef-tab).
                if call.params["drop_spare"]?.boolValue == true { services.cache.cef.dropSpareWindow() }
                return DebugCEF.report(services)
            },
            // Remote localhost proxy: port, counters, recent outcomes.
            .mainActor("debug.remote-localhost") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(services.remoteLocalhost.report())
            },
            // Every Chromium page's origin, hidden state and renderer client ids (bench_power.py loaded).
            .mainActor("debug.cef_pages") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(debugCEFPagesReport(services))
            },
            // Chromium process failures, restart state, crash reports.
            .mainActor("debug.crashes") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugCrashes.report(services))
            },
        ])
        #endif
        #if DEBUG || CMUX_BENCH_HOOKS
        // Deliberately blocks the main thread (watchdog and bench self-test).
        service.router.register([
            .mainActor("debug.home.drive") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugHomeNativeFixture.drive(call.params, services: services))
            },
            .mainActor("debug.window_record") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(services.windowRecord.start(call.params, services: services))
            },
            .async("debug.shortcut_hints") { [weak services] call in
                await DebugShortcutHintControl().handle(call.params, services: services)
            }.withDeadline(.fixed(.seconds(4))),
            .mainActor("debug.showcase.seed") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugShowcase.seed(call.params, services: services))
            },
            .mainActor("debug.scene.list") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(CaptureSceneRegistry(services: services).list())
            },
            .async("debug.scene.render") { [weak services] call in
                guard let services = await MainActor.run(body: { services }) else { return .null }
                let registry = await MainActor.run { CaptureSceneRegistry(services: services) }
                return await registry.render(call.params)
            }.withDeadline(.fixed(.seconds(30))),
            .mainActor("debug.webkit_inspector") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugWebInspector.handle(call.params, services: services))
            },
            // Open popup panels (sized window.open popups).
            .mainActor("debug.popups") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugPopups.report(call.params, services: services))
            },
            // Scripted input into the real agent cursor stacks (visual checks).
            .mainActor("debug.agent_cursor.demo") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugAgentCursorDemo.handle(call.params, services: services))
            },
            // A click on an agent cursor's name tag, as the person's (the tag is a link).
            .mainActor("debug.agent_cursor.click_tag") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugAgentCursor.clickTag(call.params, services: services))
            },
            // An injected key is input: it runs ahead of queued requests and batches yield to it (MainWorkClass.input).
            .mainActor("debug.key") { [weak services, player = keySequencePlayer] call in
                guard let services else { return .value(.null) }
                if call.params["sequence"] != nil { return .value(DebugKey.sendSequence(call.params, services: services, player: player)) }
                return .value(DebugKey.send(call.params, services: services))
            }.injectingInput(),
            // The app's resign and become-active path without activating it (DebugAppActivation).
            .mainActor("debug.app_activation") { call in
                .value(DebugAppActivation.send(call.params))
            },
            .mainActor("debug.palette.capture") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugPaletteCapture.capture(call.params, services: services))
            },
            // `debug.palette.entries {scope?, path}`: writes the scope's ranker input (the
            // palette-ranking eval fixture, plans/cmux-next/palette-ranking.md) to `path`.
            .async("debug.palette.entries") { [weak services] call in
                try await DebugPaletteEntries.write(call.params, services: services)
            },
            .mainActor("debug.omnibar_mouse") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugOmnibar.mouse(call.params, services: services))
            },
            // One omnibar click from rest to the frame that shows focus and select-all (omnibar-mousedown-latency).
            .async("debug.omnibar_bench") { [weak services] call in
                await DebugOmnibarClickBench.run(call.params, services)
            }.withDeadline(.fixed(.seconds(15))),
            // One file-picker open, click to the frame that shows it (DebugOpenPanelBench).
            .async("debug.open_panel_bench") { [weak services] call in
                await DebugOpenPanelBench.run(call.params, services)
            }.withDeadline(.fixed(.seconds(30))),
            .mainActor("debug.omnibar_type") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugOmnibar.type(call.params, services: services))
            },
            .async("debug.window.ax_set_frame") { [weak services] call in
                guard let services = await MainActor.run(body: { services }) else { return .null }
                return await DebugAXFrame.run(call.params, services: services)
            },
            .mainActor("debug.home_native_fixture.open") { [weak services] call in
                guard let services else { return .value(.null) }
                let attachments = call.params["attachments"]?.boolValue ?? false
                // `new`: one more fixture tab, also when the window lists one already.
                let fresh = call.params["new"]?.boolValue ?? false
                return .value(DebugHomeNativeFixture.open(services: services, attachments: attachments, fresh: fresh))
            },
            // `debug.home.attach` {paths: [..] | path, via: drop|paste|pick}:
            // files enter the shown Home composer through the same intake as
            // a real drop, paste or pick (HomeNativeTranscriptView.attachFiles).
            .mainActor("debug.home.attach") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugHomeNativeFixture.attach(call.params, services: services))
            },
            .mainActor("debug.window_list") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugWindowList.list(services: services))
            },
            .mainActor("debug.page_popup") { _ in .value(DebugPagePopup.list()) },
            DebugWindowSnapshot.controlMethod(services: services),
            .mainActor("debug.window.focus") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugKey.focusWindow(call.params, services: services))
            },
            .mainActor("debug.window_frame") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugLayers.setWindowFrame(call.params, services: services))
            },
            .mainActor("debug.drop_highlight") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugLayers.dropHighlight(call.params, services: services))
            },
            .mainActor("debug.sidebar_filter") { [weak services] call in .value(services.map { DebugSidebarFilter.run(call.params, $0) } ?? .null) },
            .mainActor("debug.sidebar_rows") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugSidebarRows.report(call.params, services: services))
            },
            .mainActor("debug.sidebar_wheel") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugSidebarWheel.post(call.params, services: services))
            },
            .mainActor("debug.sidebar_rename") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugKey.beginSidebarRename(call.params, services: services))
            },
            // CEF's own DevTools wait is 5 s (CEFRuntime.devToolsTimeout); the 2 s
            // control-plane deadline cut off replies that arrive between 2 and 5 s.
            .async("debug.cef.devtools") { [weak services] call in
                await DebugExtensions.devTools(call.params, services)
            }.withDeadline(.fixed(.seconds(6))),
            .async("debug.browser_retirement") { [weak services] _ in
                guard let services else { return .null }
                do {
                    let result = try await BrowserRetirementProbe(engine: services.cache.cef).run { page in
                        let entry = BrowserEntry(tab: page)
                        return (entry, entry.chrome)
                    }
                    return .object(result.mapValues(JSONValue.bool))
                } catch {
                    return .object(["error": .string(String(describing: error))])
                }
            }.withDeadline(.fixed(.seconds(30))),
            // React agent pane: synthetic transcript, fling and frame/typing
            // timing through the page's cmuxAcpmuxDebug, WebContent pid.
            .async("debug.agent_pane") { [weak services] call in
                await DebugAgentPane.handle(call.params, services)
            }.withDeadline(.fixed(DebugAgentPane.deadline)),
            // Instant new tab: spares, opening times, the field (new-tab.md 2.3); new terminal stages (cx-6so.58).
            .async("debug.new_tab") { [weak services] call in
                await DebugNewTab.handle(call.params, services)
            }.withDeadline(.fixed(.seconds(15))), DebugNewTerminalTrace.method(services),
            // Agent chat open: stages and the pane's surface per frame (Leo 2026-10-22, the black gap).
            DebugChatOpenTrace.method(services),
            // R131: hover card retarget timing across the focused strip's tabs.
            .async("debug.hover_sweep") { [weak services] call in
                guard let services else { return .null }
                return await DebugHoverSweep.run(call.params, services: services)
            }.withDeadline(.fixed(.seconds(15))),
            // `debug.pointer_hover {point: [x, y] | null, window?}`: real tracking-area
            // enter/move/exit at a window point (cx-tupd; a headless host cannot hover).
            .mainActor("debug.pointer_hover") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugPointerHover.run(call.params, services: services))
            },
            .mainActor("debug.menu") { [weak services] call in
                .value(DebugExtensions.menu(call.params, presenter: services?.contextMenus))
            },
            // The browser-data import offer on the first browser tab.
            .mainActor("debug.browser_import_offer") { [weak services] call in
                .value(services.map { DebugBrowserImportOffer.run(call.params, services: $0) } ?? .null)
            },
            .mainActor("debug.onboarding") { [weak services] call in
                .value(services.map { DebugOnboarding.run(call.params, services: $0) } ?? .null)
            },
            .mainActor("debug.extensions.toolbar") { [weak services] call in
                .value(services.map { DebugExtensionToolbar.toolbar(call.params, $0) } ?? .null)
            },
            .mainActor("debug.extensions.click") { [weak services] call in
                .value(services.map { DebugExtensionToolbar.click(call.params, $0) } ?? .null)
            },
            .mainActor("debug.extensions.menu") { [weak services] call in
                .value(services.map { DebugExtensionToolbar.menu(call.params, $0) } ?? .null)
            },
            .mainActor("debug.extensions.drag") { [weak services] call in
                .value(services.map { DebugExtensionToolbar.drag(call.params, $0) } ?? .null)
            },
            .mainActor("debug.extensions.popup") { [weak services] call in
                .value(services.map { DebugExtensionToolbar.popup(call.params, $0) } ?? .null)
            },
            // The file pages: tabs, recovery drafts, toasts, and the notice's Open.
            .async("debug.filepages") { [weak services] call in
                let services = await MainActor.run { services }
                guard let services else { return .null }
                return await DebugFilePages.run(call.params, services)
            },
            // The quit sheet (Quit and the local terminals).
            .mainActor("debug.quit") { [weak services] call in
                .value(services.map { DebugQuit.run(call.params, $0) } ?? .null)
            },
            // A quit as a logout does (REOPEN VIDEO): {reason: "logout"}.
            .mainActor("debug.app.terminate") { [weak services] call in
                .value(services.map { $0.quit.origins.debugTerminate(reason: call.params["reason"]?.stringValue) { NSApplication.terminateFromRunLoop() } }
                    .map { refusal in refusal.map { .object(["error": .string($0)]) } ?? .object(["terminating": .bool(true)]) } ?? .null)
            },
            // The burst bench's record: each press's outcome, refusals, terminal grids, echoes and redraws.
            // `status`: whether the burst is done (its keys posted, no create still asking the daemon, no
            // grid waiting to go or for its echo), the signal the bench waits for before it reads the counts.
            .mainActor("debug.burst") { [weak services, player = keySequencePlayer] call in
                .value(services.map { services in
                    services.burstTrace.control(call.params, facts: [
                        "key_repeat_delay_s": .number(NSEvent.keyRepeatDelay), "key_repeat_interval_s": .number(NSEvent.keyRepeatInterval),
                        "sequence_playing": .bool(player.isPlaying),
                        "pending_intents": JSONValue(services.daemon.store.pendingIntents.count),
                        "resize_idle": .bool(services.resizes.isIdle),
                        // The attach machines' own due echoes: a closed view is gone from the cache, so it never waits.
                        "terminals_awaiting_echo": JSONValue(services.cache.terminals.values.filter { $0.io.awaitsEcho }.count),
                    ])
                } ?? .null)
            },
            // Every window's toasts (R96): list, a person's action run, the undo key.
            .mainActor("debug.toast") { [weak services] call in
                .value(services.map { DebugToast.run(call.params, $0) } ?? .null)
            },
            // Every open cmux dialog (R96): list, fixtures, keys, presses.
            .mainActor("debug.dialog") { [weak services] call in
                .value(services.map { DebugDialog.run(call.params, $0) } ?? .null)
            },
            // A dialog's open and close, frame after frame, with its card and scrim progress.
            .async("debug.dialog_strip") { [weak services] call in
                await DebugDialog.strip(call.params, services)
            }.withDeadline(.fixed(.seconds(20))),
            // The Passwords reveal sheet with a fixture secret (no store, no device owner prompt), so a
            // live check proves the sheet stays out of screen capture (cx-bkyn9).
            .mainActor("debug.passwords_reveal") { [weak services] call in
                let secret = SecretBytes(copying: Array((call.params["secret"]?.stringValue ?? "fixture").utf8))
                let surface = NativePasswordSecretSurface(), anchor = services?.windows.active?.window?.contentView
                // task-owner: the reveal sheet's own lifetime; it ends when the sheet is answered or the app quits
                Task { await surface.reveal(secret, site: call.params["site"]?.stringValue ?? "example.com", username: "proof", anchor: anchor) }
                return .value(["shown": .bool(true)])
            },
            .mainActor("debug.extensions.prompt") { [weak services] call in
                .value(services.map { DebugExtensionPrompts.run(call.params, $0) } ?? .null)
            },
            .mainActor("debug.crash.app") { [weak services] call in DebugCrashes.crashApp(call.params, services?.crashReporting) },
            .mainActor("debug.crash.exception") { [weak services] _ in .value(DebugCrashes.raiseException(services?.crashReporting)) },
            // Low Power Mode as WebKit tabs follow it: `enabled: bool` overrides
            // macOS (no sudo needed), `enabled: null` follows macOS again.
            .mainActor("debug.low_power_mode") { call in
                let mode = LowPowerMode.system
                if let enabled = call.params["enabled"] { mode.override = enabled.boolValue }
                return .value(["enabled": .bool(mode.isEnabled), "override": mode.override.map { .bool($0) } ?? .null,
                               "system": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)])
            },
            // Reduce Transparency as overlays follow it (toasts, menus): `enabled: bool`
            // overrides macOS for this app only, `enabled: null` follows macOS again.
            .mainActor("debug.reduce_transparency") { call in
                let mode = ReduceTransparency.shared
                if let enabled = call.params["enabled"] { mode.override = enabled.boolValue }
                return .value(["enabled": .bool(mode.isEnabled), "override": mode.override.map { .bool($0) } ?? .null,
                               "system": .bool(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)])
            },
            .mainActor("debug.stall") { call in
                let milliseconds = min(max(call.params["ms"]?.intValue ?? 100, 1), 1_000)
                let end = ContinuousClock.now + .milliseconds(milliseconds)
                while ContinuousClock.now < end {}
                return .value(["stalled_ms": .number(Double(milliseconds))])
            },
        ])
        // Sidebar fixtures and the sidebar focus ring live in CmuxNextSidebar behind DEBUG only, so a bench
        // build (CMUX_BENCH_HOOKS without DEBUG) registers these routes in DEBUG builds alone.
        #if DEBUG
        service.router.register([
            .mainActor("debug.sidebar_nested_fixture") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugSidebarNestedFixture.show(call.params, services: services))
            },
            // Captures of Add Device: a fixture listing (network and ~/.ssh/config rows), never the capture host's tailnet.
            .mainActor("debug.add_device") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugAddDevice.show(call.params, services: services))
            },
            // Captures of the Machines section's joined rows: fixture machines, no platform or account.
            .mainActor("debug.joined_machines") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugAddDevice.showJoined(call.params, services: services))
            },
            // Captures of This Mac's join consent: a fixture joined status, its switches and the one-time sheet.
            .mainActor("debug.join_consent") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugJoinConsent.show(call.params, services: services))
            },
            // Captures of the daemon update: a board state, an ssh machine fixture and its header's tooltip.
            .mainActor("debug.daemon_update") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugSidebarNestedFixture.daemonUpdate(call.params, services: services))
            },
            // Captures of an update handoff: `debug.terminal_state {state, surface?}` sets live terminal tabs'
            // `terminal_state` (adopting, reconnecting, running, ...) as the daemon's push does; no daemon restart.
            .mainActor("debug.terminal_state") { [weak services] call in
                guard let services else { return .value(.null) }
                let name = call.params["state"]?.stringValue ?? "adopting"
                guard let state = TerminalTabState(rawValue: name) else {
                    return .value(["error": .string("unknown state"), "state": .string(name)])
                }
                let surface = call.params["surface"]?.intValue.map { SurfaceID(rawValue: UInt64($0)) }
                let set = services.daemon.store.debugSetTerminalState(state, surface: surface)
                return .value(["state": .string(name), "surfaces": .array(set.map { .number(Double($0.rawValue)) })])
            },
            // Captures of a Cloud machine's menu: a fixture header and `cloudWorkspace`, with no machine, sign-in or network.
            .mainActor("debug.cloud_machine_fixture") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugCloudMachineFixture.show(call.params, services: services))
            },
            // Captures of the workspace, tab and pane right-click menus and their folders (tour:object-menu-*).
            .mainActor("debug.object_menu") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugObjectMenu.run(call.params, services: services))
            },
            .mainActor("debug.sidebar_group_drag") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugSidebarGroupDrag.run(call.params, services: services))
            },
            // `debug.view_key {view, key, modifiers?, window?}`: a real key-down/up into a
            // named view made first responder; `debug.focus_ring`: the sidebar's ring (cx-tupd).
            .mainActor("debug.view_key") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugViewKey.send(call.params, services: services))
            }.injectingInput(),
            .mainActor("debug.focus_ring") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugViewKey.focusRingReport(call.params, services: services))
            },
        ])
        #endif
        #endif
        let publisher = ControlSnapshotPublisher(router: service.router, services: services, frames: frames)
        self.publisher = publisher
        publisher.start()
    }

    func stop() {
        publisher?.stop()
        service?.stop()
    }
}
