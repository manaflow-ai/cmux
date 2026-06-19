import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class SurfaceMetadataHostStub: SurfaceMetadataHosting {
    var focusedPanelId: UUID?
    var currentDirectory: String = ""
    var surfaceTabBarDirectory: String?
    var isRemoteTmuxMirror = false
    var requestedDirectories: [UUID: String] = [:]
    var restoredGuardedDirectories: [UUID: String] = [:]
    var agentPorts: [Int] = []
    var detectedPorts: [Int] = []
    var forwardedPorts: [Int] = []
    var listeningPorts: [Int] = []
    private(set) var clearedGuardedPanelIds: [UUID] = []
    private(set) var listeningPortWrites = 0
    private(set) var ignoredReports: [(panelId: UUID, missing: String, saved: String, reported: String)] = []

    var surfaceMetadataFocusedPanelId: UUID? { focusedPanelId }

    var surfaceMetadataCurrentDirectory: String {
        get { currentDirectory }
        set { currentDirectory = newValue }
    }

    var surfaceMetadataSurfaceTabBarDirectory: String? {
        get { surfaceTabBarDirectory }
        set { surfaceTabBarDirectory = newValue }
    }

    var surfaceMetadataIsRemoteTmuxMirror: Bool { isRemoteTmuxMirror }

    func surfaceMetadataRequestedWorkingDirectory(panelId: UUID) -> String? {
        requestedDirectories[panelId]
    }

    func surfaceMetadataRestoredGuardedWorkingDirectory(panelId: UUID) -> String? {
        restoredGuardedDirectories[panelId]
    }

    func surfaceMetadataClearRestoredGuardedWorkingDirectory(panelId: UUID) {
        clearedGuardedPanelIds.append(panelId)
        restoredGuardedDirectories.removeValue(forKey: panelId)
    }

    var surfaceMetadataAgentListeningPorts: [Int] { agentPorts }
    var surfaceMetadataRemoteDetectedPorts: [Int] { detectedPorts }
    var surfaceMetadataRemoteForwardedPorts: [Int] { forwardedPorts }

    var surfaceMetadataListeningPorts: [Int] {
        get { listeningPorts }
        set {
            listeningPorts = newValue
            listeningPortWrites += 1
        }
    }

    func surfaceMetadataLogIgnoredRestoredCwdReport(
        panelId: UUID,
        missingVolumeRoot: String,
        savedDirectory: String,
        reportedDirectory: String
    ) {
        ignoredReports.append((panelId, missingVolumeRoot, savedDirectory, reportedDirectory))
    }
}

@MainActor
struct WorkspaceSurfaceMetadataModelTests {
    private typealias Model = WorkspaceSurfaceMetadataModel<Int>

    private func makeModel() -> (Model, SurfaceRegistryModel<Int>, SurfaceMetadataHostStub) {
        let registry = SurfaceRegistryModel<Int>()
        let host = SurfaceMetadataHostStub()
        let model = Model(registry: registry)
        model.attach(host: host)
        return (model, registry, host)
    }

    @Test
    func updatePanelDirectoryStoresTrimmedDirectoryInRegistry() {
        let (model, registry, _) = makeModel()
        let panelId = UUID()

        #expect(model.updatePanelDirectory(panelId: panelId, directory: "  /work/repo  "))
        #expect(registry.panelDirectories[panelId] == "/work/repo")
    }

    @Test
    func updatePanelDirectoryRejectsEmptyDirectory() {
        let (model, registry, _) = makeModel()
        let panelId = UUID()

        #expect(!model.updatePanelDirectory(panelId: panelId, directory: "   "))
        #expect(registry.panelDirectories[panelId] == nil)
    }

    @Test
    func updatePanelDirectorySyncsFocusedWorkspaceDirectories() {
        let (model, _, host) = makeModel()
        let panelId = UUID()
        host.focusedPanelId = panelId

        _ = model.updatePanelDirectory(panelId: panelId, directory: "/focused")

        #expect(host.currentDirectory == "/focused")
        #expect(host.surfaceTabBarDirectory == "/focused")
    }

    @Test
    func updatePanelDirectoryDoesNotSyncWhenPanelIsNotFocused() {
        let (model, _, host) = makeModel()
        host.focusedPanelId = UUID()
        host.currentDirectory = "/keep"

        _ = model.updatePanelDirectory(panelId: UUID(), directory: "/other")

        #expect(host.currentDirectory == "/keep")
        #expect(host.surfaceTabBarDirectory == nil)
    }

    @Test
    func liveReportClearsGuardWhenReportedMatchesRestored() {
        let (model, registry, host) = makeModel()
        let panelId = UUID()
        host.restoredGuardedDirectories[panelId] = "/restored"

        #expect(model.updatePanelDirectory(panelId: panelId, directory: "/restored"))
        #expect(host.clearedGuardedPanelIds == [panelId])
        #expect(registry.panelDirectories[panelId] == "/restored")
    }

    @Test
    func liveReportIgnoredWhenRestoredVolumeUnmounted() {
        let (model, registry, host) = makeModel()
        let panelId = UUID()
        // A /Volumes/<name> path whose volume root does not exist on disk.
        let missingVolumeDir = "/Volumes/CmuxTestMissingVolume-\(UUID().uuidString)/work"
        host.restoredGuardedDirectories[panelId] = missingVolumeDir

        #expect(!model.updatePanelDirectory(panelId: panelId, directory: "/different"))
        #expect(registry.panelDirectories[panelId] == nil)
        #expect(host.ignoredReports.count == 1)
        #expect(host.ignoredReports.first?.reported == "/different")
        #expect(host.clearedGuardedPanelIds.isEmpty)
    }

    @Test
    func restoredSnapshotMetadataBypassesGuard() {
        let (model, registry, host) = makeModel()
        let panelId = UUID()
        host.restoredGuardedDirectories[panelId] = "/Volumes/Missing-\(UUID().uuidString)/x"

        #expect(
            model.updatePanelDirectory(
                panelId: panelId,
                directory: "/snapshot",
                source: .restoredSnapshotMetadata
            )
        )
        #expect(registry.panelDirectories[panelId] == "/snapshot")
        #expect(host.ignoredReports.isEmpty)
    }

    @Test
    func resolvedWorkingDirectoryPrefersFocusedPanelDirectory() {
        let (model, registry, host) = makeModel()
        let panelId = UUID()
        host.focusedPanelId = panelId
        registry.panelDirectories[panelId] = "/panel-dir"
        host.requestedDirectories[panelId] = "/requested"
        host.currentDirectory = "/current"

        #expect(model.resolvedWorkingDirectory() == "/panel-dir")
    }

    @Test
    func resolvedWorkingDirectoryFallsThroughToCurrent() {
        let (model, _, host) = makeModel()
        host.focusedPanelId = UUID()
        host.currentDirectory = "/current"

        #expect(model.resolvedWorkingDirectory() == "/current")
    }

    @Test
    func configTrackingDirectoryReturnsNilForRemoteTmuxMirror() {
        let (model, registry, host) = makeModel()
        let panelId = UUID()
        host.isRemoteTmuxMirror = true
        registry.panelDirectories[panelId] = "/home/remote"

        #expect(model.configTrackingDirectory(for: panelId) == nil)
    }

    @Test
    func configTrackingDirectoryPrefersPanelThenRequestedThenCurrent() {
        let (model, registry, host) = makeModel()
        let panelId = UUID()
        host.requestedDirectories[panelId] = "/requested"
        host.currentDirectory = "/current"

        #expect(model.configTrackingDirectory(for: panelId) == "/requested")

        registry.panelDirectories[panelId] = "/panel"
        #expect(model.configTrackingDirectory(for: panelId) == "/panel")
    }

    @Test
    func recomputeListeningPortsFusesSortsAndDeduplicates() {
        let (model, registry, host) = makeModel()
        registry.surfaceListeningPorts = [UUID(): [3000, 8080], UUID(): [3000]]
        host.agentPorts = [9000]
        host.detectedPorts = [8080]
        host.forwardedPorts = [22]

        model.recomputeListeningPorts()

        #expect(host.listeningPorts == [22, 3000, 8080, 9000])
    }

    @Test
    func recomputeListeningPortsSkipsWriteWhenUnchanged() {
        let (model, registry, host) = makeModel()
        registry.surfaceListeningPorts = [UUID(): [3000]]
        model.recomputeListeningPorts()
        let writesAfterFirst = host.listeningPortWrites

        model.recomputeListeningPorts()

        #expect(host.listeningPortWrites == writesAfterFirst)
    }

    @Test
    func unmountedVolumeRootReturnsNilForNonVolumePath() {
        #expect(Model.unmountedVolumeRoot(for: "/Users/me/work") == nil)
        #expect(Model.unmountedVolumeRoot(for: "   ") == nil)
    }
}
