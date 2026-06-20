import Foundation
import Testing

@testable import CmuxWorkspaces
import CmuxTerminalCore

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

    @Test("A nil remote environment leaves the base environment unchanged")
    func mergeEnvironmentNilRemote() {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/me"]
        #expect(coordinator.mergedStartupEnvironment(base: base, remoteEnvironment: nil) == base)
    }

    @Test("A remote environment is overlaid over the base, remote winning on collisions")
    func mergeEnvironmentOverlays() {
        let base = ["PATH": "/usr/bin", "HOME": "/Users/me"]
        let remote = ["HOME": "/home/remote", "CMUX_REMOTE": "1"]
        #expect(
            coordinator.mergedStartupEnvironment(base: base, remoteEnvironment: remote)
                == ["PATH": "/usr/bin", "HOME": "/home/remote", "CMUX_REMOTE": "1"]
        )
    }

    @Test("An empty remote environment returns the base unchanged (non-nil empty is still a merge)")
    func mergeEnvironmentEmptyRemote() {
        let base = ["A": "1"]
        #expect(coordinator.mergedStartupEnvironment(base: base, remoteEnvironment: [:]) == base)
    }

    @Test("No startup command leaves the inherited config untouched, including nil")
    func holdPaneNoCommand() {
        #expect(
            coordinator.configHoldingPaneAfterStartupCommand(
                inheritedConfig: nil,
                hasStartupCommand: false
            ) == nil
        )
        var config = CmuxSurfaceConfigTemplate()
        config.fontSize = 17
        let resolved = coordinator.configHoldingPaneAfterStartupCommand(
            inheritedConfig: config,
            hasStartupCommand: false
        )
        #expect(resolved?.fontSize == 17)
        #expect(resolved?.waitAfterCommand == false)
    }

    @Test("A startup command sets waitAfterCommand on the inherited config")
    func holdPanePromotesExistingConfig() {
        var config = CmuxSurfaceConfigTemplate()
        config.fontSize = 17
        let resolved = coordinator.configHoldingPaneAfterStartupCommand(
            inheritedConfig: config,
            hasStartupCommand: true
        )
        #expect(resolved?.waitAfterCommand == true)
        // Other fields are preserved.
        #expect(resolved?.fontSize == 17)
    }

    @Test("A startup command with no inherited config synthesizes a fresh wait-after-command template")
    func holdPaneSynthesizesFreshConfig() {
        let resolved = coordinator.configHoldingPaneAfterStartupCommand(
            inheritedConfig: nil,
            hasStartupCommand: true
        )
        #expect(resolved != nil)
        #expect(resolved?.waitAfterCommand == true)
    }
}
