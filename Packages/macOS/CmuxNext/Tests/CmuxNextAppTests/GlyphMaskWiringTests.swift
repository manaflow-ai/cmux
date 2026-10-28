import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextMemory
import Testing

/// The production wiring of `sharedGlyphMasks`: off (the default) gives the scope
/// tree no cache, so every label keeps its own images; on shares one cache, a consumer in the report.
@MainActor @Suite(.serialized) struct GlyphMaskWiringTests {
    private static let budget = SubsystemBudget.forMemory(physicalBytes: 16 << 30, gpuResidentAvailable: false)

    private static func services(enabling names: Set<String> = []) -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                        overrides: FeatureOverrides(environmentEnabled: names))
        return services
    }

    private static func reported(by services: AppServices) -> Bool {
        services.memoryCoordinator.report(budget: budget).consumers.contains { $0.name == "chrome-glyph-masks" }
    }

    @Test func theFeatureOffSharesNoCache() {
        let services = Self.services()
        #expect(!services.features.isEnabled(.sharedGlyphMasks), "the feature must default off")
        let scope = ThemeScope(level: .room)
        AppMemoryConsumers(services: services).registerGlyphMasks(in: scope)
        #expect(scope.glyphMasks == nil)
        #expect(!Self.reported(by: services))
    }

    @Test func theFeatureOnSharesOneCacheWithTheScopeTree() {
        let services = Self.services(enabling: [Feature.sharedGlyphMasks.name])
        let scope = ThemeScope(level: .room)
        AppMemoryConsumers(services: services).registerGlyphMasks(in: scope)
        let masks = scope.sharedGlyphMasks
        #expect(masks != nil)
        #expect(ThemeScope(level: .workspace, parent: scope).glyphMasks === masks)
        #expect(Self.reported(by: services))
    }
}
