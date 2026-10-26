import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextControl
import CmuxNextDesign
import CmuxNextMemory
import CmuxNextSettings
import Foundation
import Testing

#if DEBUG || CMUX_BENCH_HOOKS
/// `debug.hibernation.pressure` sets the app's one memory coordinator's override and hands the same
/// level to browser hibernation in the same turn (p07-memory-004), so a bench that feeds pressure
/// through the socket measures what the coordinator and hibernation do together.
@MainActor @Suite(.serialized)
struct DebugHibernationPressureTests {
    @Test func overrideChangesCoordinatorAndHibernationTogether() async throws {
        let app = Self.app()
        for level in [MemoryPressureLevel.critical, .warning, .critical] {
            let reply = try await app.call(["level": .string(level.rawValue)])
            #expect(app.services.memoryCoordinator.level == level)
            #expect(app.services.memoryCoordinator.pressureOverride == level)
            #expect(app.hibernation.pressure == level)
            #expect(reply == .object(["level": .string(level.rawValue), "override": .string(level.rawValue),
                                      "pressure": .string(level.rawValue)]))
        }
    }

    @Test func noneClearsTheOverrideAndBothFollowTheKernelLevel() async throws {
        let app = Self.app()
        _ = try await app.call(["level": .string("critical")])
        let reply = try await app.call(["level": .string("none")])
        let coordinator = app.services.memoryCoordinator
        #expect(coordinator.pressureOverride == nil)
        #expect(coordinator.level == coordinator.kernelLevel)
        #expect(app.hibernation.pressure == coordinator.level)
        #expect(reply == .object(["level": .string(coordinator.level.rawValue), "override": .null,
                                  "pressure": .string(coordinator.level.rawValue)]))
    }

    @Test func anUnknownLevelChangesNothing() async throws {
        let app = Self.app()
        _ = try await app.call(["level": .string("warning")])
        let reply = try await app.call(["level": .string("severe")])
        #expect(reply == .object(["error": .string("level must be normal, warning, critical or none")]))
        #expect(app.services.memoryCoordinator.level == .warning)
        #expect(app.hibernation.pressure == .warning)
    }

    struct App {
        let services: AppServices
        let hibernation: BrowserHibernation
        let router: ControlRouter

        func call(_ params: [String: JSONValue]) async throws -> JSONValue {
            try await router.handle(ControlRequest(id: "1", method: "debug.hibernation.pressure", params: params)).get()
        }
    }

    /// An app whose hibernation follows a source the test never drives, so only the override moves it.
    static func app() -> App {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = BrowserHibernation(cache: services.cache, memoryPressure: MemoryPressureEvents(source: ManualMemoryPressureSource()),
                                             lowPower: LowPowerMode(enabled: false))
        services.cache.hibernation = hibernation
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: services.registry), settings: nil)
        router.register(DebugHibernationControl.methods(services))
        return App(services: services, hibernation: hibernation, router: router)
    }
}
#endif
