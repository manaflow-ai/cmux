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
/// `debug.hibernation.pressure` sets the app's one memory coordinator's override, and the coordinator
/// hands the same level to browser hibernation (its registered level consumer) in the same turn,
/// so a bench that feeds pressure through the socket measures what
/// the coordinator and hibernation do together.
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

    /// A held override survives kernel events in both the coordinator and hibernation, and after
    /// `none` both follow the kernel again: hibernation takes its level through the coordinator.
    @Test func kernelEventsDoNotMoveEitherWhileTheOverrideHolds() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let kernel = ManualMemoryPressureSource()
        let pressure = MemoryPressureEvents(source: kernel)
        let coordinator = MemoryCoordinator(pressure: pressure, slicer: HeldSlices())
        let hibernation = BrowserHibernation(cache: services.cache, memory: coordinator, deadlines: services.mainDeadlines)
        hibernation.start()

        _ = DebugHibernationControl.applyOverride(.critical, coordinator: coordinator, hibernation: hibernation)
        for level in [MemoryPressureLevel.warning, .normal] {
            kernel.send(level)
            #expect(coordinator.level == .critical, "the kernel's \(level) replaced the coordinator's override")
            #expect(hibernation.pressure == .critical, "the kernel's \(level) replaced hibernation's override")
        }

        let reply = DebugHibernationControl.applyOverride(nil, coordinator: coordinator, hibernation: hibernation)
        #expect(reply == .object(["level": .string("normal"), "override": .null, "pressure": .string("normal")]))
        kernel.send(.warning)
        #expect(coordinator.level == .warning)
        #expect(hibernation.pressure == .warning)
        hibernation.stop()
        withExtendedLifetime((services, pressure)) {}
    }

    /// Keeps release slices and never runs them: no consumer registers here.
    final class HeldSlices: MemoryReleaseSlicer {
        var slices: [@MainActor () -> Void] = []
        func scheduleSlice(_ slice: @escaping @MainActor () -> Void) { slices.append(slice) }
    }

    struct App {
        let services: AppServices
        let hibernation: BrowserHibernation
        let router: ControlRouter

        func call(_ params: [String: JSONValue]) async throws -> JSONValue {
            try await router.handle(ControlRequest(id: "1", method: "debug.hibernation.pressure", params: params)).get()
        }
    }

    /// An app whose hibernation is registered with the app's memory coordinator, so the override reaches
    /// it only through the coordinator.
    static func app() -> App {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let hibernation = BrowserHibernation(cache: services.cache, memory: services.memoryCoordinator, deadlines: services.mainDeadlines)
        services.cache.hibernation = hibernation
        hibernation.start()
        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: services.registry), settings: nil)
        router.register(DebugHibernationControl.methods(services))
        return App(services: services, hibernation: hibernation, router: router)
    }
}
#endif
