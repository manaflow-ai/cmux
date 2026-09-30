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
        let probe = frameProbe
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
            // Window membership and the window invariants (no window
            // without a workspace).
            .mainActor("debug.windows") { [weak services] _ in
                guard let services, let windows = services.windows else { return .value(.null) }
                return .value(WindowInvariants.report(windows))
            },
            // Omnibar state machine vs its field editor (focus.md section 7).
            .mainActor("debug.omnibar") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugOmnibar.report(call.params, services: services))
            },
            // App overlays vs content child windows (Chromium pages).
            .mainActor("debug.layers") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugLayers.report(services: services))
            },
            .mainActor("debug.surfaces") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(SurfaceDiagnosticsReport.make(services))
            },
            // CPU and memory per tab and workspace, two samples `interval_ms` apart.
            .async("resources") { [weak services] call in
                let services = await MainActor.run { services }
                return try await ResourceControl.run(call.params, services: services)
            },
            // Idle wakeups: ledger, display-link clients, process CPU (idle-wakeups.md).
            .async("debug.wakeups") { call in await DebugWakeups.report(call.params) },
            // Chromium start: trigger (tab or warm reason), timings, footprint.
            .mainActor("debug.cef") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugCEF.report(services))
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
            .mainActor("debug.key") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugKey.send(call.params, services: services))
            },
            .mainActor("debug.mouse") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugOmnibar.mouse(call.params, services: services))
            },
            .async("debug.window.ax_set_frame") { [weak services] call in
                guard let services = await MainActor.run(body: { services }) else { return .null }
                return await DebugAXFrame.run(call.params, services: services)
            },
            .mainActor("debug.window_frame") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugLayers.setWindowFrame(call.params, services: services))
            },
            .mainActor("debug.drop_highlight") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugLayers.dropHighlight(call.params, services: services))
            },
            .mainActor("debug.sidebar_rename") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugKey.beginSidebarRename(call.params, services: services))
            },
            .async("debug.cef.devtools") { [weak services] call in
                await DebugExtensions.devTools(call.params, services)
            },
            .mainActor("debug.menu") { call in .value(DebugExtensions.menu(call.params)) },
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
