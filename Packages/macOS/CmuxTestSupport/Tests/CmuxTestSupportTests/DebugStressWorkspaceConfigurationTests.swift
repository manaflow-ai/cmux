#if DEBUG
import Foundation
import Testing
@testable import CmuxTestSupport

@Suite("DebugStressWorkspaceConfiguration")
struct DebugStressWorkspaceConfigurationTests {
    @Test func standardMatchesLegacyConstants() {
        let config = DebugStressWorkspaceConfiguration.standard
        #expect(config.workspaceTitlePrefix == "Debug Perf - ")
        #expect(config.workspaceCount == 20)
        #expect(config.paneCount == 4)
        #expect(config.tabsPerPane == 4)
        #expect(config.yieldInterval == 4)
        #expect(config.surfaceLoadTimeoutSeconds == 10.0)
    }

    @Test func expectedSurfaceCountIsProductOfKnobs() {
        let config = DebugStressWorkspaceConfiguration(
            workspaceTitlePrefix: "T",
            workspaceCount: 3,
            paneCount: 4,
            tabsPerPane: 2,
            yieldInterval: 4,
            surfaceLoadTimeoutSeconds: 1
        )
        #expect(config.expectedSurfaceCount == 24)
    }

    @Test func standardExpectedSurfaceCountIs320() {
        #expect(DebugStressWorkspaceConfiguration.standard.expectedSurfaceCount == 320)
    }
}

@Suite("DebugStressSurfaceLoadStats")
struct DebugStressSurfaceLoadStatsTests {
    @Test func emptyIsAllZero() {
        let stats = DebugStressSurfaceLoadStats.empty
        #expect(stats.pendingSurfaces == 0)
        #expect(stats.loadedPanels == 0)
        #expect(stats.failedPanels == 0)
        #expect(stats.attempts == 0)
        #expect(stats.elapsedMs == 0)
    }
}
#endif
