import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextSettings
import Foundation

/// `action.run` as the cmux CLI sends it, through a control router wired the way the app wires its own
/// (`AppControl`): the registry bridge publishes the catalog, and a ``ControlSnapshotPublisher`` publishes
/// the topology and the daemons' event sequences. `wait: true` answers once a snapshot reflects every daemon
/// command the run sent, its own and any it joined (a focus move's window-record save); a router nothing
/// publishes to never loads its topology, so such a run could only end at its deadline (aws-m4pro-8, 2026-11-01).
@MainActor
struct CloudCLIActionRun {
    let services: AppServices
    var deadline: Duration = .seconds(60)

    /// Runs `params` (`action.run`'s); its error when it stopped.
    func callAsFunction(_ params: [String: CmuxNextSettings.JSONValue]) async -> ControlError? {
        let bridge = RegistryControlBridge(registry: services.registry)
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: bridge, settings: nil,
                                   configuration: ControlRouter.Configuration(requestDeadline: deadline), frameSource: Frames())
        bridge.attach(to: router)
        defer { bridge.detach() }
        // A private notification center: other suites' windows keying and closing never publish this snapshot.
        let publisher = ControlSnapshotPublisher(router: router, services: services, frames: Frames(), notifications: NotificationCenter())
        publisher.start()
        defer { publisher.stop() }
        if case .failure(let error) = await router.handle(ControlRequest(id: "1", method: "action.run", params: params)) { return error }
        return nil
    }

    /// The next main-actor turn for each frame.
    struct Frames: ControlFrameSource {
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { Task { @MainActor in work() } }
    }
}
