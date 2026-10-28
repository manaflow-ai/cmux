import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextFeatures
import CmuxNextMemory
import Foundation
import Testing

/// The production wiring of `memoryAgentAndControlCaches`: off (the default) adds
/// none of its consumers to the app's memory coordinator; on adds the agent pane's three caches, the
/// control service's idempotency cache and the login environment, each live in the report.
@MainActor @Suite(.serialized) struct AgentAndControlCachesWiringTests {
    private static let names: Set<String> = [
        "agent-new-tab-frames", "agent-chat-tails", "agent-project-icons", "control-idempotency", "login-environment",
    ]
    private static let budget = SubsystemBudget.forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false)

    private static func services(enabling names: Set<String> = []) -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                        overrides: FeatureOverrides(environmentEnabled: names))
        return services
    }

    private static func controlService() throws -> ControlService {
        try ControlService.prepare(
            registry: ActionRegistry(catalog: []), settingsStore: nil,
            configuration: .init(path: "/tmp/cnw-\(UUID().uuidString.prefix(8).lowercased()).sock", accessMode: .automation),
            identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0))
    }

    /// What AppServices' registration, `AppControl.start` and the daemon line add, as the report names them.
    private static func registered(by services: AppServices, service: ControlService) -> Set<String> {
        let consumers = AppMemoryConsumers(services: services)
        consumers.registerAgentPaneCaches()
        consumers.registerControlCaches(service)
        consumers.registerDaemonCaches()
        return Set(services.memoryCoordinator.report(budget: budget).consumers.map(\.name)).intersection(names)
    }

    @Test func theFeatureOffRegistersNone() throws {
        let services = Self.services()
        #expect(!services.features.isEnabled(.memoryAgentAndControlCaches), "the feature must default off")
        let service = try Self.controlService()
        defer { service.stop() }

        #expect(Self.registered(by: services, service: service).isEmpty)
    }

    @Test func theFeatureOnRegistersEachCache() throws {
        let services = Self.services(enabling: [Feature.memoryAgentAndControlCaches.name])
        let service = try Self.controlService()
        defer { service.stop() }

        #expect(Self.registered(by: services, service: service) == Self.names)
    }
}
