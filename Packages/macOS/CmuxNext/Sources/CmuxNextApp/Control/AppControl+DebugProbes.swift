import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowserImport
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextEnergy
import CmuxNextErrorJournal
import CmuxNextInput
import CmuxNextInputDiagnostics
import CmuxNextLaunch
import CmuxNextPages
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextTerminal
import CmuxNextTrace
import CmuxNextWakeups

#if DEBUG || CMUX_BENCH_HOOKS
/// The debug probes (tagged DEV and bench builds): frames, damage, main-thread budgets, timings and the
/// per-area reports. One control launch group (`AppControl.launchGroups`).
extension AppControl {
    /// Frames, damage, budgets, timings and the per-area reports.
    func registerDebugProbeMethods(_ services: AppServices, on router: ControlRouter) {
        router.register([
            .mainActor("debug.frames") { [probe = frameProbe] call in probe.handle(call.params) }.withDeadline(.fixed(RenderFrameLog.armDeadline)),
            // Render damage per owner over a window (render-idle-damage.py: the MQ-damage-owners queue).
            .mainActor("debug.damage") { [damage = damageWindow] call in
                switch call.params["action"]?.stringValue ?? "read" {
                case "start": .followUp { JSONValue(foundation: await damage.start().foundationObject) ?? .null }
                case "stop": .value(JSONValue(foundation: damage.stop().foundationObject) ?? .null)
                default: .value(JSONValue(foundation: damage.read().foundationObject) ?? .null)
                }
            }.withDeadline(.fixed(RenderFrameLog.armDeadline)),
            // Main-thread blocking call sites since launch (threading-model.md); {"reset": true} zeroes the counts.
            BlockingControl(detector: services.blocking).method,
            // Observations per owner: armed, evaluated, applied, show re-reads, hosting bodies; {"reset": true} zeroes them.
            ObservationsControl(ledger: services.observations).method,
            // Lane queue wait and run time per lane and priority (RUN-13); {"reset": true} zeroes them.
            WorkControl(work: services.work).method,
            // The detector's context per kind of thread and a running item's raise, per macOS (RUN-10, os-matrix threads).
            PoolContextControl(work: services.work, detector: services.blocking).method,
            // The main-thread scheduler's per-frame budget: tasks, input yields, deferrals, longest task per class,
            // the run loop's turns, per owner the wait and run percentiles, and its idle class's periods under
            // "idle"; main only copies, the turns and owners fold off it.
            .async("debug.main_budget") { [budget = mainWork.budget, board = mainWork.board, idle = mainWork.idle] call in
                await board.mainBudgetReport(budget, idle: idle, reset: call.params["reset"]?.boolValue == true)
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
            .mainActor("debug.timings") { [weak services] call in
                .value(DebugTimings.handle(call.params, launchValues: services?.launchValues.values ?? [:]))
            },
            // The startup trace (CMUX_TRACE_STARTUP): write what it holds now, its file and counts.
            DebugTimings.startupTraceMethod,
            // This launch's milestones, temperature, startup tasks and first frame (bench-startup.py, startup-queue.py).
            .mainActor("debug.startup") { [startupReport] _ in .value(try JSONValue(foundation: startupReport.report.foundationObject()) ?? .null) },
            // The launch's main jobs and main turns until startup completed (startup-queue.py mainjobs):
            // copied on main, symbolized off it.
            .mainActor("debug.startup.main_jobs") { [weak services] _ in
                guard let services, let census = services.environment.mainJobCensus else { return .value(["main_job_census": ["armed": false]]) }
                let snapshot = census.snapshot(mainTasks: services.launchStartup.map { MainJobCensus.mainTasks($0.log) } ?? [])
                return .followUp {
                    let symbolicator = StackSymbolicator(map: nil) // Debug and bench executables keep their names: no map read
                    let report = MainJobCensusReport(snapshot) { addresses in
                        symbolicator.frames(for: addresses).map { .init(image: $0.image, symbol: $0.symbol, imageOffset: $0.imageOffset) }
                    }
                    return try JSONValue(foundation: report.foundationObject()) ?? .null
                }
            },
            // The tasks that started on the cooperative pool until startup completed (startup-queue.py globaljobs):
            // copied and symbolized off main.
            .mainActor("debug.startup.global_jobs") { [weak services] _ in
                guard let census = services?.environment.globalJobCensus else { return .value(["global_job_census": ["armed": false]]) }
                return .followUp {
                    let symbolicator = StackSymbolicator(map: nil) // Debug and bench executables keep their names: no map read
                    let report = GlobalJobCensusReport(census.snapshot()) { addresses in
                        symbolicator.frames(for: addresses).map { .init(image: $0.image, symbol: $0.symbol, imageOffset: $0.imageOffset) }
                    }
                    return try JSONValue(foundation: report.foundationObject()) ?? .null
                }
            },
            // The timers, deadlines and folder watches armed until startup completed, with their first fires
            // (startup-queue.py arms): copied and encoded off main.
            .async("debug.startup.arms") { _ in JSONValue(foundation: WakeupLedger.shared.armCensus.snapshot().foundationObject) ?? .null },
            // Each tab switch's own time: intent to shown, and to the next frame (perf-gate.py).
            .mainActor("debug.tab_switch") { call in .value(DebugTabSwitch.timer.handle(call.params, key: "switches")) },
            // Each pane focus move's own time: intent to settled, and to the next frame (perf-gate.py pane_focus).
            .mainActor("debug.pane_focus") { call in .value(DebugPaneFocus.handle(call.params)) },
            // Each workspace switch's own time: input to shown content, and to its commit (perf-budgets.py).
            .mainActor("debug.workspace_switch") { call in .value(DebugWorkspaceSwitch.timer.handle(call.params, key: "switches")) },
            // Each new workspace's own time: its create (with the press's age) to its sidebar row drawn, and the walks between (perf-gate.py).
            .mainActor("debug.new_workspace") { call in .value(PendingWorkspaceRows.shared.newRows.timer.handle(call.params, key: "creates")) },
            // Work per layout change: pane snapshots, applies, topology sends (bench_pane_scale.py).
            .mainActor("debug.layout_counters") { [weak services] call in
                let roots = services?.windows.controllers.flatMap { $0.mountedContents.map(\.layoutView) } ?? []
                return .value(DebugLayoutCounters.handle(call.params, roots: roots, hiddenWork: services?.hiddenLayoutWork,
                                                         visibilityWork: services?.visibilityWorkCounts))
            },
            // A full-screen or Space transition: notifications, resizes, layout passes (fullscreen-transition.py).
            .mainActor("debug.window_transition") { [events = services.workspaceEvents] call in
                .value(DebugWindowTransition.shared.handle(call.params, workspaceEvents: events))
            },
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
                return .value(DebugHints.report(services.windowHints, menus: services.menuTracking, params: call.params))
            },
            // The Settings, History and Cloud preload in the preload slot; `action`: `drop`, `preload`.
            .mainActor("debug.page_preload") { [weak services] call in
                .value(services?.pagePreloads.debugReport(action: call.params["action"]?.stringValue) ?? .null)
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
            .mainActor("debug.themes") { [weak services] _ in .value(services.map { DebugThemes.report(services: $0) } ?? .null) },
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
            // Overlay reorders per event cycle; `reset: true` starts the counts over first.
            .mainActor("debug.overlay") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugLayers.overlay(services: services, params: call.params))
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
            .mainActor("debug.screens") { [weak services] _ in .value(services.map { DebugScreens.report(services: $0) } ?? .null) },
            // The action signposts' commit boundary against this macOS's display observers.
            .mainActor("debug.commit_boundary") { _ in .value(DebugCommitBoundary().report()) },
            // Idle wakeups: ledger, display-link clients, process CPU (idle-wakeups.md).
            .async("debug.wakeups") { [budgeted = mainWork.frames, parent = services.cache.chromium.source.helperParent] call in
                await DebugWakeups.report(call.params, budgeted: budgeted, helperParent: parent.pid)
            },
            // Energy Saver policy and inputs, main wake queue, top wakers, process energy; simulated inputs (p14-energy.md).
            EnergyReport(services: services).method, EnergyReport.simulateMethod(services: services),
            // Chromium start: trigger (tab or warm reason), timings, footprint.
            .mainActor("debug.cef") { [weak services] call in
                guard let services else { return .value(.null) }
                // {"side_panel": "<control>"} runs a side panel header control first.
                if let control = call.params["side_panel"]?.stringValue { DebugCEF.pressSidePanel(control, services: services) }
                // {"drop_spare": true} closes the spare Chromium window (its memory cost, PL-cef-tab).
                if call.params["drop_spare"]?.boolValue == true { services.cache.cef.closeUntakenSpareWindows() }
                // {"file_dialog_choose": ["/abs/path", ...]} or {"file_dialog_cancel": true} answers the newest page
                // file chooser in cmux's picker, as a choice there would (host mode, chromiumHostFileDialogs).
                if let paths = call.params["file_dialog_choose"]?.arrayValue?.compactMap(\.stringValue) {
                    _ = services.cache.cef.answerHostFileDialog(with: paths.map { URL(filePath: $0) })
                } else if call.params["file_dialog_cancel"]?.boolValue == true {
                    _ = services.cache.cef.answerHostFileDialog(with: nil)
                }
                // {"color_chooser_pick": 0xRRGGBB} or {"color_chooser_close": true}: the open <input type=color>'s panel.
                if let color = call.params["color_chooser_pick"]?.intValue { _ = services.cache.cef.pickHostColor(UInt32(truncatingIfNeeded: color)) }
                if call.params["color_chooser_close"]?.boolValue == true { _ = services.cache.cef.closeHostColorChooser() }
                return .value(DebugCEF.report(services))
            },
            // Remote localhost proxy: port, counters, recent outcomes.
            .mainActor("debug.remote-localhost") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(services.remoteLocalhost.report())
            },
            // Chromium process failures, restart state, crash reports.
            .mainActor("debug.crashes") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugCrashes.report(services))
            },
        ])
        // Synthetic sleep, wake and display-change notices on the centers macOS posts them on (lifecycle-sweep.py, RUN-12).
        // raw-observer-allow: the center the synthetic sleep and wake notices are posted on; nothing observes it here
        router.register(LifecycleSimulationControl(notices: .appKit, workspaceCenter: NSWorkspace.shared.notificationCenter,
                                                   workspace: NSWorkspace.shared, appCenter: .default, application: NSApp).methods)
    }
}

extension LifecycleSimulationControl.Notices {
    /// What macOS posts at a sleep, a wake and a display change, in its order (lifecycle-sweep.py, RUN-12).
    static let appKit = Self(sleep: [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification],
                             wake: [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification],
                             // raw-observer-allow: posted by debug.simulate.display, never observed: the notice every screen observer hears
                             display: NSApplication.didChangeScreenParametersNotification)
}
#endif
