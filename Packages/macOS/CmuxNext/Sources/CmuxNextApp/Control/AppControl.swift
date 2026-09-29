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
        ])
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
