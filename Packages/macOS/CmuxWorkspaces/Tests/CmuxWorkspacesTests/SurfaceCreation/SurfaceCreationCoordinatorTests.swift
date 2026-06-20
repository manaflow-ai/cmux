import Foundation
import Testing

@testable import CmuxWorkspaces

@MainActor
@Suite("SurfaceCreationCoordinator")
struct SurfaceCreationCoordinatorTests {
    private let coordinator = SurfaceCreationCoordinator()

    @Test("Whitespace-only and empty candidates normalize to nil")
    func normalizeEmpty() {
        #expect(coordinator.normalizedWorkingDirectory(nil) == nil)
        #expect(coordinator.normalizedWorkingDirectory("") == nil)
        #expect(coordinator.normalizedWorkingDirectory("   \n\t ") == nil)
    }

    @Test("A non-empty candidate is trimmed")
    func normalizeTrims() {
        #expect(coordinator.normalizedWorkingDirectory("  /tmp/a  ") == "/tmp/a")
        #expect(coordinator.normalizedWorkingDirectory("/tmp/b") == "/tmp/b")
    }

    @Test("Startup directory resolves to the first non-empty candidate in order")
    func startupDirectoryFirstNonEmpty() {
        #expect(
            coordinator.resolvedStartupWorkingDirectory(candidates: [nil, "  ", "/tmp/source", "/home"])
                == "/tmp/source"
        )
        #expect(
            coordinator.resolvedStartupWorkingDirectory(candidates: ["/req", "/tmp/source"])
                == "/req"
        )
    }

    @Test("Startup directory is nil when every candidate is empty")
    func startupDirectoryAllEmpty() {
        #expect(coordinator.resolvedStartupWorkingDirectory(candidates: []) == nil)
        #expect(coordinator.resolvedStartupWorkingDirectory(candidates: [nil, "", "  "]) == nil)
    }

    @Test("A seeded lineage root is kept when runtime is close")
    func fontPointsKeepsRoot() {
        let resolved = coordinator.resolvedInheritanceFontPoints(
            rootedFontPoints: 14,
            runtimeFontPoints: 14.02,
            inheritedConfigFontPoints: 20
        )
        #expect(resolved == 14)
    }

    @Test("A diverged runtime zoom promotes the runtime value over the root")
    func fontPointsPromotesRuntime() {
        let resolved = coordinator.resolvedInheritanceFontPoints(
            rootedFontPoints: 14,
            runtimeFontPoints: 18,
            inheritedConfigFontPoints: 20
        )
        #expect(resolved == 18)
    }

    @Test("A diverged root with no runtime keeps the root")
    func fontPointsRootWithoutRuntime() {
        let resolved = coordinator.resolvedInheritanceFontPoints(
            rootedFontPoints: 14,
            runtimeFontPoints: nil,
            inheritedConfigFontPoints: 20
        )
        #expect(resolved == 14)
    }

    @Test("No usable root falls back to the inherited config font size")
    func fontPointsInheritedConfig() {
        #expect(
            coordinator.resolvedInheritanceFontPoints(
                rootedFontPoints: nil,
                runtimeFontPoints: 9,
                inheritedConfigFontPoints: 16
            ) == 16
        )
        // A non-positive root is treated as "no lineage" and falls through.
        #expect(
            coordinator.resolvedInheritanceFontPoints(
                rootedFontPoints: 0,
                runtimeFontPoints: 9,
                inheritedConfigFontPoints: 16
            ) == 16
        )
    }

    @Test("No root and no positive config font size falls back to runtime")
    func fontPointsRuntimeFallback() {
        #expect(
            coordinator.resolvedInheritanceFontPoints(
                rootedFontPoints: nil,
                runtimeFontPoints: 11,
                inheritedConfigFontPoints: 0
            ) == 11
        )
        #expect(
            coordinator.resolvedInheritanceFontPoints(
                rootedFontPoints: nil,
                runtimeFontPoints: nil,
                inheritedConfigFontPoints: 0
            ) == nil
        )
    }
}
