import AppKit
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `debug.window_snapshot` captures on the main actor. On a capture mini that also runs builds and
/// tests, or while the app is still launching, the wait for the main actor passed the 2 s
/// control-plane deadline: the snapshot timed out, the capture had no still, and pr-capture refused
/// it. The capture itself takes about 50 ms once it runs, so the method keeps its own deadline and
/// waits behind a busy main actor instead of failing.
@MainActor @Suite(.serialized) struct DebugWindowSnapshotDeadlineTests {
    @Test func aSnapshotWaitsBehindABusyMainActor() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: services.registry), settings: nil,
                                   configuration: ControlRouter.Configuration(requestDeadline: .milliseconds(50)))
        router.register([DebugWindowSnapshot.controlMethod(services: services)])
        let request = ControlRequest(id: "1", method: "debug.window_snapshot", params: ["window": .string("999999999")])
        let entered = DispatchSemaphore(value: 0)
        let reply = Task.detached {
            entered.signal()
            return await router.handle(request)
        }
        Self.block(on: entered)  // the request's clock runs before the main actor goes busy
        // The main actor stays busy past the control-plane deadline, as on a loaded capture mini.
        let busyUntil = ContinuousClock.now + .milliseconds(400)
        while ContinuousClock.now < busyUntil {}
        // With the control-plane deadline this was a `timeout` failure.
        let value = try await reply.value.get()
        #expect(value["error"]?.stringValue == "no such window")
    }

    /// A synchronous wait, which async code may not call directly.
    private nonisolated static func block(on semaphore: DispatchSemaphore) {
        semaphore.wait()
    }
}
