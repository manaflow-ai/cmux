import CmuxNextActions
import CmuxNextControl
import CmuxNextSettings

/// The App's control-socket wiring (architecture.md 5a): the main-thread
/// watchdog (from launch), the socket server with a display-link frame
/// source for the main-actor work queue, the snapshot publisher, and the
/// App-only debug methods.
@MainActor
final class AppControl {
    let watchdog = MainThreadWatchdog()
    private let frames = DisplayLinkFrameScheduler()
    private let frameProbe = DebugFrameProbe()
    private(set) var service: ControlService?
    private var publisher: ControlSnapshotPublisher?

    var socketPath: String? { service?.socketPath }

    /// Starts stall detection. Call first thing at launch.
    func startWatchdog() {
        watchdog.start()
    }

    func start(registry: ActionRegistry, settings: SettingsController, launch: LaunchIdentity, services: AppServices) throws {
        let service = try ControlService.start(registry: registry, settings: settings, launch: launch,
                                               frameSource: frames, watchdog: watchdog)
        self.service = service
        let probe = frameProbe
        service.router.register([
            .mainActor("debug.frames") { call in .value(probe.handle(call.params)) },
            // Focus model vs AppKit vs Ghostty per window (plans/cmux-next/focus.md).
            .mainActor("debug.focus") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugFocus.report(services: services))
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
            // Chromium start: trigger (tab or warm reason), timings, footprint.
            .mainActor("debug.cef") { [weak services] _ in
                guard let services else { return .value(.null) }
                return .value(DebugCEF.report(services))
            },
        ])
        #if DEBUG
        // Deliberately blocks the main thread (watchdog and bench self-test).
        service.router.register([
            .mainActor("debug.key") { [weak services] call in
                guard let services else { return .value(.null) }
                return .value(DebugKey.send(call.params, services: services))
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
