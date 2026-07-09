import Combine
import Foundation
import Testing
@testable import CmuxWorkspaces

@MainActor
private final class SurfaceMetadataHostStub: SurfaceMetadataHosting {
    var focusedPanelId: UUID?
    var currentDirectory: String = ""
    var surfaceTabBarDirectory: String?
    var isRemoteTmuxMirror = false
    var usesRemoteDirectoryProvenance = false
    var localDirectoryFallbackPanelIds: Set<UUID>?
    var requestedDirectories: [UUID: String] = [:]
    var restoredGuardedDirectories: [UUID: String] = [:]
    var agentPorts: [Int] = []
    var detectedPorts: [Int] = []
    var forwardedPorts: [Int] = []
    var existingPanelIds: Set<UUID> = []
    private(set) var clearedGuardedPanelIds: [UUID] = []
    private(set) var clearedResumeSessionPanelIds: [UUID] = []
    private(set) var ignoredReports: [(panelId: UUID, missing: String, saved: String, reported: String)] = []
    private(set) var restoredCwdDecisions: [
        (panelId: UUID, event: String, saved: String, reported: String)
    ] = []

    var surfaceMetadataFocusedPanelId: UUID? { focusedPanelId }

    func surfaceMetadataPanelExists(panelId: UUID) -> Bool {
        existingPanelIds.contains(panelId)
    }

    var surfaceMetadataCurrentDirectory: String {
        get { currentDirectory }
        set { currentDirectory = newValue }
    }

    var surfaceMetadataSurfaceTabBarDirectory: String? {
        get { surfaceTabBarDirectory }
        set { surfaceTabBarDirectory = newValue }
    }

    var surfaceMetadataIsRemoteTmuxMirror: Bool { isRemoteTmuxMirror }

    var surfaceMetadataUsesRemoteDirectoryProvenance: Bool { usesRemoteDirectoryProvenance }

    func surfaceMetadataAllowsLocalDirectoryFallback(panelId: UUID) -> Bool {
        localDirectoryFallbackPanelIds?.contains(panelId) ?? true
    }

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

    func surfaceMetadataClearRestoredResumeSessionWorkingDirectory(panelId: UUID) {
        clearedResumeSessionPanelIds.append(panelId)
    }

    var surfaceMetadataAgentListeningPorts: [Int] { agentPorts }
    var surfaceMetadataRemoteDetectedPorts: [Int] { detectedPorts }
    var surfaceMetadataRemoteForwardedPorts: [Int] { forwardedPorts }

    func surfaceMetadataLogIgnoredRestoredCwdReport(
        panelId: UUID,
        missingVolumeRoot: String,
        savedDirectory: String,
        reportedDirectory: String
    ) {
        ignoredReports.append((panelId, missingVolumeRoot, savedDirectory, reportedDirectory))
    }

    func surfaceMetadataLogRestoredCwdDecision(
        panelId: UUID,
        event: String,
        savedDirectory: String,
        reportedDirectory: String
    ) {
        restoredCwdDecisions.append((panelId, event, savedDirectory, reportedDirectory))
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

        #expect(model.listeningPorts == [22, 3000, 8080, 9000])
    }

    @Test
    func recomputeListeningPortsSkipsWriteWhenUnchanged() {
        // Bind `host`: it is held `weak` by the model, so discarding it would
        // deallocate it and make `recomputeListeningPorts` early-return.
        let (model, registry, host) = makeModel()
        _ = host
        registry.surfaceListeningPorts = [UUID(): [3000]]

        // The model's `listeningPortsPublisher` replays the seed then emits on
        // every landed `didSet`. The unchanged-value guard must keep the second
        // recompute from emitting, so a subscriber sees seed [] + first-write
        // [3000] and no third value.
        var emissions: [[Int]] = []
        let cancellable = model.listeningPortsPublisher.sink { emissions.append($0) }
        defer { cancellable.cancel() }

        model.recomputeListeningPorts()
        let countAfterFirst = emissions.count

        model.recomputeListeningPorts()

        #expect(emissions.count == countAfterFirst)
        #expect(model.listeningPorts == [3000])
    }

    @Test
    func applyPanelShellActivityStateIgnoresAbsentPanel() {
        let (model, registry, _) = makeModel()
        let panelId = UUID()

        #expect(model.applyPanelShellActivityState(panelId: panelId, state: .commandRunning) == nil)
        #expect(registry.panelShellActivityStates[panelId] == nil)
    }

    @Test
    func applyPanelShellActivityStateWritesAndReturnsPreviousStateOnTransition() {
        let (model, registry, host) = makeModel()
        let panelId = UUID()
        host.existingPanelIds = [panelId]

        // First transition: unknown (default) -> commandRunning.
        #expect(model.applyPanelShellActivityState(panelId: panelId, state: .commandRunning) == .unknown)
        #expect(registry.panelShellActivityStates[panelId] == .commandRunning)

        // Second transition reports the prior commandRunning state.
        #expect(model.applyPanelShellActivityState(panelId: panelId, state: .promptIdle) == .commandRunning)
        #expect(registry.panelShellActivityStates[panelId] == .promptIdle)
    }

    @Test
    func applyPanelShellActivityStateIgnoresUnchangedState() {
        let (model, registry, host) = makeModel()
        let panelId = UUID()
        host.existingPanelIds = [panelId]
        registry.panelShellActivityStates[panelId] = .promptIdle

        #expect(model.applyPanelShellActivityState(panelId: panelId, state: .promptIdle) == nil)
        #expect(registry.panelShellActivityStates[panelId] == .promptIdle)
    }

    @Test
    func unmountedVolumeRootReturnsNilForNonVolumePath() {
        #expect(Model.unmountedVolumeRoot(for: "/Users/me/work") == nil)
        #expect(Model.unmountedVolumeRoot(for: "   ") == nil)
    }

    @Test
    func conversationMessagePreviewCollapsesWhitespaceAndTrims() {
        #expect(Model.conversationMessagePreview(from: "  hello   world  ") == "hello world")
        #expect(Model.conversationMessagePreview(from: nil) == nil)
        #expect(Model.conversationMessagePreview(from: "   \n ") == nil)
    }

    @Test
    func conversationMessagePreviewTruncatesPastMaxLength() {
        let preview = Model.conversationMessagePreview(from: String(repeating: "a", count: 10), maxLength: 4)
        #expect(preview == "aaaa...")
    }

    @Test
    func recordConversationMessageStoresDedupedPreview() {
        let (model, _, _) = makeModel()

        #expect(model.recordConversationMessage("  Done.  "))
        #expect(model.latestConversationMessage == "Done.")
        // Unchanged deduped preview is rejected.
        #expect(!model.recordConversationMessage("Done."))
        // Empty/whitespace message is rejected and leaves the prior value.
        #expect(!model.recordConversationMessage("   "))
        #expect(model.latestConversationMessage == "Done.")
    }

    @Test
    func recordSubmittedMessageStampsConversationSubmittedAndTime() {
        let (model, _, _) = makeModel()
        let before = Date()

        #expect(model.recordSubmittedMessage("ship it"))
        #expect(model.latestConversationMessage == "ship it")
        #expect(model.latestSubmittedMessage == "ship it")
        #expect((model.latestSubmittedAt ?? .distantPast) >= before)

        // Whitespace-only submission records nothing.
        model.latestSubmittedAt = nil
        #expect(!model.recordSubmittedMessage(" \n "))
        #expect(model.latestSubmittedAt == nil)
    }
}
