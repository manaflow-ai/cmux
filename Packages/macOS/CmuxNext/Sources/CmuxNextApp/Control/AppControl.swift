import AppKit
import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings
import CmuxNextWakeups

/// The App's control-socket wiring (architecture.md 5a): the main-thread
/// watchdog (from launch), the socket server with a display-link frame
/// source for the main-actor work queue, the snapshot publisher, and the
/// App-only debug methods.
@MainActor
final class AppControl {
    let watchdog = MainThreadWatchdog()
    private let frames = FrameBatcher(owner: "Control.frames")
    private let frameProbe = DebugFrameProbe()
    private(set) var service: ControlService?
    private var publisher: ControlSnapshotPublisher?

    var socketPath: String? { service?.socketPath }

    private var inputMonitor: Any?

    /// Starts stall and busy detection. Call first thing at launch.
    func startWatchdog() {
        watchdog.start()
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
        registerSyncBarrier(service.router, daemon: services.daemon)
        let probe = frameProbe
        service.router.register(HistoryControl.methods(services: services))
        service.router.register(TabSearchControl.methods())
        service.router.register(PaletteScopeControl.methods(services: services, router: service.router))
        service.router.register(BookmarkControl.methods(services: services))
        service.router.register(FeedControl.methods(services: services))
        service.router.register(KeybindingControl.methods(services: services))
        service.router.register(SettingsControl.methods(services: services))
        service.router.register([
            .mainActor("debug.frames") { call in .value(probe.handle(call.params)) },
            // Measured animation spans (plans/cmux-next/motion.md).
            .mainActor("debug.motion") { call in .value(DebugMotion.handle(call.params)) },
            // Launch, palette-open and terminal-creation spans (bench-stalls.py).
            .mainActor("debug.timings") { call in .value(DebugTimings.handle(call.params)) },
            // Focus model vs AppKit vs Ghostty per window (plans/cmux-next/focus.md).
            .mainActor("debug.focus") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugFocus.report(services: services))
            },
            // Home per window and the local conversation projection (home.md).
            .mainActor("debug.home") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugHome.report(services: services))
            },
            // Room, workspace and terminal theme scopes.
            .mainActor("debug.themes") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugThemes.report(services: services))
            },
            // Window membership and the window invariants (no window
            // without a workspace).
            .mainActor("debug.windows") { [weak services] _ in
                guard let services, let windows = services.windows else { return .value(.null) }
                guard case .object(var report) = WindowInvariants.report(windows) else { return .value(.null) }
                // Every workspace the app closed or kept after it lost its
                // last pane, with the cause (EmptyWorkspaceRepair).
                report["emptied_workspaces"] = .array((services.emptyWorkspaces?.decisions ?? []).map {
                    .object(["key": .string($0.key.rawValue), "cause": .string(String(describing: $0.cause))])
                })
                return .value(.object(report))
            },
            // Omnibar state machine vs its field editor (focus.md section 7).
            .mainActor("debug.omnibar") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugOmnibar.report(call.params, services: services))
            },
            // Unread tabs, attention marks, banners and the dismissal log
            // (plans/cmux-next/notifications.md); "click" runs a banner click.
            .mainActor("debug.notifications") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugNotifications.handle(call.params, services: services))
            },
            // App overlays vs content child windows (Chromium pages).
            .mainActor("debug.layers") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugLayers.report(services: services))
            },
            // The one hover card: machine phase, card window, timer, monitor.
            .mainActor("debug.hover_cards") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(.object(services.hoverCards.report.mapValues(JSONValue.string)))
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
            .mainActor("debug.screens") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugScreens.report(services: services))
            },
            // `text: true` adds each terminal mirror's viewport text. DEBUG builds add each
            // terminal pane's `terminal_id` and `host_pid` (SurfaceHostReport).
            .async("debug.surfaces") { [weak services] call in
                let includeText = call.params["text"]?.boolValue == true
                let built: (JSONValue, [SurfaceHostReport.Target])? = await MainActor.run {
                    guard let services else { return nil }
                    #if DEBUG
                    let targets = SurfaceHostReport.targets(services)
                    #else
                    let targets: [SurfaceHostReport.Target] = []
                    #endif
                    return (SurfaceDiagnosticsReport.make(services, includeText: includeText), targets)
                }
                guard let (report, targets) = built else { return .null }
                #if DEBUG
                return SurfaceHostReport.annotate(report, identities: await SurfaceHostReport.identities(targets))
                #else
                return report
                #endif
            },
            // CPU and memory per tab and workspace, two samples `interval_ms` apart.
            .async("resources") { [weak services] call in
                let services = await MainActor.run { services }
                return try await ResourceControl.run(call.params, services: services)
            }.withDeadline(.fixed(ResourceControl.deadline)),
            // Idle wakeups: ledger, display-link clients, process CPU (idle-wakeups.md).
            .async("debug.wakeups") { call in await DebugWakeups.report(call.params) },
            // Chromium start: trigger (tab or warm reason), timings, footprint.
            .mainActor("debug.cef") { [weak services] call in
                guard let services else { return .value(.null) }
                // {"side_panel": "<control>"} runs a side panel header control first.
                if let control = call.params["side_panel"]?.stringValue { DebugCEF.pressSidePanel(control, services: services) }
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
            // Installed Chrome extensions, shortcuts and toolbar badges.
            .mainActor("browser.extensions") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(ExtensionControl.report(services))
            },
        ])
        #if DEBUG
        // Deliberately blocks the main thread (watchdog and bench self-test).
        service.router.register([
            .mainActor("debug.home.drive") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugHomeNativeFixture.drive(call.params, services: services))
            },
            .mainActor("debug.window_record") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugWindowRecord.start(call.params, services: services))
            },
            .mainActor("debug.showcase.seed") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugShowcase.seed(call.params, services: services))
            },
            .mainActor("debug.webkit_inspector") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugWebInspector.handle(call.params, services: services))
            },
            // Open popup panels (sized window.open popups).
            .mainActor("debug.popups") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugPopups.report(call.params, services: services))
            },
            .mainActor("debug.key") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugKey.send(call.params, services: services))
            },
            .mainActor("debug.palette.capture") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugPaletteCapture.capture(call.params, services: services))
            },
            .mainActor("debug.mouse") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugOmnibar.mouse(call.params, services: services))
            },
            .async("debug.window.ax_set_frame") { [weak services] call in
                guard let services = await MainActor.run(body: { services }) else { return .null }
                return await DebugAXFrame.run(call.params, services: services)
            },
            .mainActor("debug.home_native_fixture.open") { [weak services] call in
                guard let services else { return .value(.null) }
                let attachments = call.params["attachments"]?.boolValue ?? false
                return .value(DebugHomeNativeFixture.open(services: services, attachments: attachments))
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
            .mainActor("debug.window_snapshot") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugWindowSnapshot.capture(call.params, services: services))
            },
            .mainActor("debug.window_frame") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugLayers.setWindowFrame(call.params, services: services))
            },
            .mainActor("debug.drop_highlight") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugLayers.dropHighlight(call.params, services: services))
            },
            .mainActor("debug.sidebar_rows") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugSidebarRows.report(services: services))
            },
            .mainActor("debug.sidebar_rename") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugKey.beginSidebarRename(call.params, services: services))
            },
            .async("debug.cef.devtools") { [weak services] call in
                await DebugExtensions.devTools(call.params, services)
            },
            // React agent pane: synthetic transcript, fling and frame/typing
            // timing through the page's cmuxAcpmuxDebug, WebContent pid.
            .async("debug.agent_pane") { [weak services] call in
                await DebugAgentPane.handle(call.params, services)
            }.withDeadline(.fixed(DebugAgentPane.deadline)),
            // Instant new tab: spares, opening times, the field (new-tab.md 2.3).
            .async("debug.new_tab") { [weak services] call in
                await DebugNewTab.handle(call.params, services)
            }.withDeadline(.fixed(.seconds(15))),
            // R131: hover card retarget timing across the focused strip's tabs.
            .async("debug.hover_sweep") { [weak services] call in
                guard let services else { return .null }
                return await DebugHoverSweep.run(call.params, services: services)
            }.withDeadline(.fixed(.seconds(15))),
            .mainActor("debug.menu") { [weak services] call in
                .value(DebugExtensions.menu(call.params, presenter: services?.contextMenus))
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
            // The quit sheet (Quit and the local terminals).
            .mainActor("debug.quit") { [weak services] call in
                .value(services.map { DebugQuit.run(call.params, $0) } ?? .null)
            },
            // Every open cmux dialog (R96): list, fixtures, keys, presses.
            .mainActor("debug.dialog") { [weak services] call in
                .value(services.map { DebugDialog.run(call.params, $0) } ?? .null)
            },
            .mainActor("debug.extensions.prompt") { [weak services] call in
                .value(services.map { DebugExtensionPrompts.run(call.params, $0) } ?? .null)
            },
            .mainActor("debug.crash.app") { call in DebugCrashes.crashApp(call.params) },
            .mainActor("debug.stall") { call in
                let milliseconds = min(max(call.params["ms"]?.intValue ?? 100, 1), 1_000)
                let end = ContinuousClock.now + .milliseconds(milliseconds)
                while ContinuousClock.now < end {}
                return .value(["stalled_ms": .number(Double(milliseconds))])
            },
        ])
        #endif
        let publisher = ControlSnapshotPublisher(router: service.router, services: services, frames: frames)
        self.publisher = publisher
        publisher.start()
    }

    /// Publishes the control snapshot synchronously (after compat intents).
    func publishSnapshotNow() {
        publisher?.publishNow()
    }

    func stop() {
        publisher?.stop()
        service?.stop()
    }
}
