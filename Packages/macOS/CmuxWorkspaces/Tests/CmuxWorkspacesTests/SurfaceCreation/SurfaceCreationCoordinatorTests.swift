import Foundation
import Testing

@testable import CmuxWorkspaces
import Bonsplit
import CmuxTerminalCore

/// A scriptable ``SurfaceCreationHosting`` stub that records the coordinator's
/// callbacks so the inheritance-config walk can be tested without a live
/// workspace, panel registry, or Ghostty surface.
@MainActor
private final class StubSurfaceCreationHost: SurfaceCreationHosting {
    /// The ordered candidate IDs the walk should iterate.
    var candidatePanelIds: [UUID] = []
    /// Per-panel inherited config, or absent when the panel has no live surface.
    var liveConfigs: [UUID: CmuxSurfaceConfigTemplate] = [:]
    /// Per-panel lineage-root font points.
    var rootedFontPoints: [UUID: Float] = [:]
    /// Per-panel runtime surface font points.
    var runtimeFontPoints: [UUID: Float] = [:]
    /// The last-known font points used for the fallback config.
    var lastKnownInheritanceFontPoints: Float?

    // Recorded writes for assertions.
    /// The lineage-root seeds applied via `commitInheritanceSelection` (a
    /// non-`nil` `rootedFontPoints` argument), in call order.
    private(set) var recordedFontPoints: [(points: Float, panelId: UUID)] = []
    /// The positive final font sizes recorded as last-known, in call order.
    private(set) var recordedLastFontPoints: [Float] = []
    /// The panel IDs remembered as inheritance sources, in call order.
    private(set) var rememberedSources: [UUID] = []
    private(set) var fallbackLogs: [Float] = []

    func configInheritanceCandidatePanelIds(
        preferredPanelId: UUID?,
        inPane preferredPaneId: PaneID?
    ) -> [UUID] {
        candidatePanelIds
    }

    func probeInheritanceCandidate(panelId: UUID) -> SurfaceInheritanceCandidateProbe? {
        guard let config = liveConfigs[panelId] else { return nil }
        return SurfaceInheritanceCandidateProbe(
            inheritedConfig: config,
            rootedFontPoints: rootedFontPoints[panelId],
            runtimeFontPoints: runtimeFontPoints[panelId]
        )
    }

    func commitInheritanceSelection(
        panelId: UUID,
        rootedFontPoints points: Float?,
        finalConfigFontPoints: Float
    ) {
        if let points {
            recordedFontPoints.append((points, panelId))
            rootedFontPoints[panelId] = points
        }
        // The host always remembers the source for a chosen live candidate,
        // matching the legacy unconditional `rememberTerminalConfigInheritanceSource`.
        rememberedSources.append(panelId)
        if finalConfigFontPoints > 0 {
            recordedLastFontPoints.append(finalConfigFontPoints)
        }
    }

    func logInheritanceFallback(fontPoints: Float) {
        fallbackLogs.append(fontPoints)
    }

    var focusedBonsplitPaneId: PaneID? { nil }
    var focusedPanelId: UUID? { nil }
    var focusedTerminalHostedView: AnyObject? { nil }
    var currentDirectory: String { "" }

    func registerProjectPanel(projectURL: URL) -> SurfaceTabDescriptor {
        makeDescriptor(title: projectURL.lastPathComponent)
    }

    func createSurfaceTab(descriptor: SurfaceTabDescriptor, kind: String, inPane paneId: PaneID) -> TabID? {
        TabID()
    }

    @discardableResult
    func reorderTab(_ tabId: TabID, toIndex index: Int) -> Bool {
        true
    }

    func publishCmuxSurfaceCreated(_ surfaceId: UUID, paneId: PaneID?, kind: String, origin: String, focused: Bool) {}

    func focusPane(_ paneId: PaneID) {}

    func selectTab(_ tabId: TabID) {}

    func applyTabSelection(tabId: TabID, inPane paneId: PaneID) {}

    func preserveSurfaceFocusAfterNonFocusSplit(
        preferredPanelId: UUID?,
        splitPanelId: UUID,
        previousHostedView: AnyObject?
    ) {}

    func discardPanelRegistration(id: UUID) {}

    func reloadProjectPanel(id: UUID) {}

    func paneId(forPanelId panelId: UUID) -> PaneID? {
        nil
    }

    func registerMarkdownPanel(filePath: String, fontSize: Double?) -> SurfaceTabDescriptor {
        makeDescriptor(title: filePath)
    }

    func splitSurface(
        _ paneId: PaneID,
        orientation: SplitOrientation,
        withTab descriptor: SurfaceTabDescriptor,
        kind: String,
        insertFirst: Bool
    ) -> PaneID? {
        PaneID()
    }

    func publishCmuxSplitCreated(
        _ paneId: PaneID,
        sourcePaneId: PaneID?,
        orientation: SplitOrientation,
        surfaceId: UUID?,
        kind: String,
        origin: String,
        focused: Bool
    ) {}

    func suppressReparentFocusUntilLayoutFollowUp(_ hostedView: AnyObject?, reason: String) {}

    func focusSurfacePanel(_ panelId: UUID) {}

    func selectSurfaceTab(panelId: UUID) {}

    func installMarkdownPanelSubscription(id: UUID) {}

    func registerFilePreviewPanel(filePath: String) -> SurfaceTabDescriptor {
        makeDescriptor(title: filePath)
    }

    func focusFilePreviewPanel(id: UUID) {}

    func installFilePreviewPanelSubscription(id: UUID) {}

    func registerAgentSessionPanel(
        providerIDRawValue: String,
        rendererKindRawValue: String,
        workingDirectory: String
    ) -> SurfaceTabDescriptor {
        makeDescriptor(title: providerIDRawValue)
    }

    func focusAgentSessionPanel(id: UUID) {}

    func installAgentSessionPanelSubscription(id: UUID) {}

    func registerExtensionBrowserPanel(title: String) -> SurfaceTabDescriptor {
        makeDescriptor(title: title)
    }

    func focusExtensionBrowserPanel(id: UUID) {}

    func registerRightSidebarToolPanel(modeRawValue: String) -> SurfaceTabDescriptor {
        makeDescriptor(title: modeRawValue)
    }

    private func makeDescriptor(title: String) -> SurfaceTabDescriptor {
        SurfaceTabDescriptor(id: UUID(), displayTitle: title, displayIcon: nil, isDirty: false)
    }
}

@MainActor
@Suite("SurfaceCreationCoordinator")
struct SurfaceCreationCoordinatorTests {
    private let coordinator = SurfaceCreationCoordinator()

    @Test("A tilde-prefixed project path expands and standardizes")
    func standardizedProjectURLExpandsTilde() {
        let home = NSHomeDirectory()
        #expect(
            coordinator.standardizedProjectURL(projectPath: "~/proj").path
                == URL(fileURLWithPath: home + "/proj").standardizedFileURL.path
        )
    }

    @Test("Project path standardization collapses dot segments")
    func standardizedProjectURLCollapsesDotSegments() {
        #expect(
            coordinator.standardizedProjectURL(projectPath: "/tmp/./a/../b").path == "/tmp/b"
        )
    }

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

    @Test("The inheritance walk picks the first live candidate and seeds a positive rooted font")
    func inheritedConfigPicksFirstLiveCandidate() {
        let host = StubSurfaceCreationHost()
        let dead = UUID()
        let live = UUID()
        let later = UUID()
        host.candidatePanelIds = [dead, live, later]
        // `dead` has no live surface, so it is skipped.
        var liveConfig = CmuxSurfaceConfigTemplate()
        liveConfig.fontSize = 12
        host.liveConfigs[live] = liveConfig
        // A seeded lineage root that diverges from runtime by > 0.05 promotes runtime.
        host.rootedFontPoints[live] = 14
        host.runtimeFontPoints[live] = 18

        let resolved = coordinator.resolveInheritedConfig(host: host, preferredPanelId: nil, inPane: nil)

        #expect(resolved?.fontSize == 18)
        // Only the live candidate's seed is recorded, never `dead` or `later`.
        #expect(host.recordedFontPoints.count == 1)
        #expect(host.recordedFontPoints.first?.points == 18)
        #expect(host.recordedFontPoints.first?.panelId == live)
        #expect(host.rememberedSources == [live])
        #expect(host.recordedLastFontPoints == [18])
        #expect(host.fallbackLogs.isEmpty)
    }

    @Test("A non-positive rooted font leaves the live config's font untouched and records it as last-known")
    func inheritedConfigKeepsConfigFontWhenNoRoot() {
        let host = StubSurfaceCreationHost()
        let live = UUID()
        host.candidatePanelIds = [live]
        var liveConfig = CmuxSurfaceConfigTemplate()
        liveConfig.fontSize = 16
        host.liveConfigs[live] = liveConfig
        // No rooted lineage and a 0 config-derived root → resolvedInheritanceFontPoints
        // falls back to the config font (16), which is not > 0-rooted, so the
        // walk does NOT overwrite config.fontSize via the rooted branch... but
        // resolvedInheritanceFontPoints returns 16 (>0), so it IS applied + seeded.
        host.runtimeFontPoints[live] = 9

        let resolved = coordinator.resolveInheritedConfig(host: host, preferredPanelId: nil, inPane: nil)

        #expect(resolved?.fontSize == 16)
        #expect(host.recordedFontPoints.first?.points == 16)
        #expect(host.recordedLastFontPoints == [16])
        #expect(host.rememberedSources == [live])
    }

    @Test("No live candidate falls back to the host's last-known font and logs the fallback")
    func inheritedConfigFallsBackToLastKnown() {
        let host = StubSurfaceCreationHost()
        host.candidatePanelIds = [UUID(), UUID()] // none have live surfaces
        host.lastKnownInheritanceFontPoints = 13

        let resolved = coordinator.resolveInheritedConfig(host: host, preferredPanelId: nil, inPane: nil)

        #expect(resolved?.fontSize == 13)
        #expect(host.fallbackLogs == [13])
        #expect(host.recordedFontPoints.isEmpty)
        #expect(host.rememberedSources.isEmpty)
    }

    @Test("No live candidate and no last-known font returns nil")
    func inheritedConfigReturnsNilWhenNothingKnown() {
        let host = StubSurfaceCreationHost()
        host.candidatePanelIds = [UUID()]
        host.lastKnownInheritanceFontPoints = nil

        #expect(coordinator.resolveInheritedConfig(host: host, preferredPanelId: nil, inPane: nil) == nil)
        #expect(host.fallbackLogs.isEmpty)
    }

    @Test("Whitespace-only and empty remote-PTY session ids normalize to nil")
    func normalizeRemotePTYSessionIDEmpty() {
        #expect(coordinator.normalizedRemotePTYSessionID(nil) == nil)
        #expect(coordinator.normalizedRemotePTYSessionID("") == nil)
        #expect(coordinator.normalizedRemotePTYSessionID("  \n\t ") == nil)
    }

    @Test("A non-empty remote-PTY session id is trimmed")
    func normalizeRemotePTYSessionIDTrims() {
        #expect(coordinator.normalizedRemotePTYSessionID("  sess-1  ") == "sess-1")
        #expect(coordinator.normalizedRemotePTYSessionID("sess-2") == "sess-2")
    }

    @Test("An empty or whitespace-only explicit command normalizes to nil")
    func normalizeExplicitInitialCommandEmpty() {
        #expect(coordinator.normalizedExplicitInitialCommand(nil) == nil)
        #expect(coordinator.normalizedExplicitInitialCommand("") == nil)
        #expect(coordinator.normalizedExplicitInitialCommand("   \n ") == nil)
    }

    @Test("A non-empty explicit command is trimmed")
    func normalizeExplicitInitialCommandTrims() {
        #expect(coordinator.normalizedExplicitInitialCommand("  ls -la  ") == "ls -la")
        #expect(coordinator.normalizedExplicitInitialCommand("echo hi") == "echo hi")
    }

    @Test("An explicit command replaces the remote command and clears the environment fold")
    func resolveStartupCommandExplicitWins() {
        let resolved = coordinator.resolveStartupCommand(
            explicitCommand: "ls",
            remoteCommand: "ssh vm"
        )
        #expect(resolved.startupCommand == "ls")
        #expect(resolved.remoteCommandForEnvironment == nil)
    }

    @Test("No explicit command falls through to the remote command for launch and environment")
    func resolveStartupCommandRemoteFallthrough() {
        let resolved = coordinator.resolveStartupCommand(
            explicitCommand: nil,
            remoteCommand: "ssh vm"
        )
        #expect(resolved.startupCommand == "ssh vm")
        #expect(resolved.remoteCommandForEnvironment == "ssh vm")
    }

    @Test("Neither an explicit nor a remote command leaves both resolved values nil")
    func resolveStartupCommandBothNil() {
        let resolved = coordinator.resolveStartupCommand(
            explicitCommand: nil,
            remoteCommand: nil
        )
        #expect(resolved.startupCommand == nil)
        #expect(resolved.remoteCommandForEnvironment == nil)
    }

    @Test("A surface is remote-tracked when it has a remote startup command")
    func tracksRemoteWhenRemoteCommandPresent() {
        #expect(
            coordinator.tracksRemoteTerminalSurface(
                remoteStartupCommand: "ssh vm",
                normalizedRemotePTYSessionID: nil
            )
        )
    }

    @Test("A surface is remote-tracked when it carries a remote-PTY session id")
    func tracksRemoteWhenSessionIDPresent() {
        #expect(
            coordinator.tracksRemoteTerminalSurface(
                remoteStartupCommand: nil,
                normalizedRemotePTYSessionID: "sess-1"
            )
        )
    }

    @Test("A surface with both a remote command and a session id is remote-tracked")
    func tracksRemoteWhenBothPresent() {
        #expect(
            coordinator.tracksRemoteTerminalSurface(
                remoteStartupCommand: "ssh vm",
                normalizedRemotePTYSessionID: "sess-1"
            )
        )
    }

    @Test("A surface with neither a remote command nor a session id is not remote-tracked")
    func tracksRemoteWhenNeitherPresent() {
        #expect(
            !coordinator.tracksRemoteTerminalSurface(
                remoteStartupCommand: nil,
                normalizedRemotePTYSessionID: nil
            )
        )
    }

    @Test("A zero final font size is not recorded as the last-known value")
    func inheritedConfigSkipsLastKnownWhenFontNonPositive() {
        let host = StubSurfaceCreationHost()
        let live = UUID()
        host.candidatePanelIds = [live]
        // Live config with font 0, no rooted lineage, no runtime → resolved font is
        // nil (no application), config.fontSize stays 0, so last-known is NOT set.
        host.liveConfigs[live] = CmuxSurfaceConfigTemplate()

        let resolved = coordinator.resolveInheritedConfig(host: host, preferredPanelId: nil, inPane: nil)

        #expect(resolved?.fontSize == 0)
        #expect(host.recordedFontPoints.isEmpty)
        #expect(host.recordedLastFontPoints.isEmpty)
        // The source is still remembered (legacy remembers on every live candidate).
        #expect(host.rememberedSources == [live])
    }
}
