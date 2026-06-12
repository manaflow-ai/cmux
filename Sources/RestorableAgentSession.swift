import Foundation
import CMUXAgentLaunch

struct RestorableAgentHookSessionRecord: Codable, Sendable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var transcriptPath: String?
    var pid: Int?
    var launchCommand: AgentLaunchCommandSnapshot?
    var isRestorable: Bool?
    var agentLifecycle: AgentHibernationLifecycleState?
    var updatedAt: TimeInterval
}

struct RestorableAgentHookSessionStoreFile: Codable, Sendable {
    var version: Int = 1
    var sessions: [String: RestorableAgentHookSessionRecord] = [:]
}

struct RestorableAgentSessionIndex: Sendable {
    static let empty = RestorableAgentSessionIndex(entriesByPanel: [:])

    struct PanelKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    struct Entry: Sendable {
        let snapshot: SessionRestorableAgentSnapshot
        let lifecycle: AgentHibernationLifecycleState?
        let updatedAt: TimeInterval
        let processIDs: Set<Int>
    }

    private let entriesByPanel: [PanelKey: Entry]
    private let entriesByPanelId: [UUID: Entry]

    private func entry(workspaceId: UUID, panelId: UUID) -> Entry? {
        entriesByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)] ?? entriesByPanelId[panelId]
    }

    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        entry(workspaceId: workspaceId, panelId: panelId)?.snapshot
    }

    func lifecycle(workspaceId: UUID, panelId: UUID) -> AgentHibernationLifecycleState? {
        entry(workspaceId: workspaceId, panelId: panelId)?.lifecycle
    }

    func updatedAt(workspaceId: UUID, panelId: UUID) -> TimeInterval? {
        entry(workspaceId: workspaceId, panelId: panelId)?.updatedAt
    }

    func processIDs(workspaceId: UUID, panelId: UUID) -> Set<Int> {
        entry(workspaceId: workspaceId, panelId: panelId)?.processIDs ?? []
    }

    func hasLiveProcess(workspaceId: UUID, panelId: UUID) -> Bool {
        !processIDs(workspaceId: workspaceId, panelId: panelId).isEmpty
    }

    init(entriesByPanel: [PanelKey: Entry]) {
        self.entriesByPanel = entriesByPanel
        var entriesByPanelId: [UUID: Entry] = [:]
        for (key, entry) in entriesByPanel {
            let existing = entriesByPanelId[key.panelId]
            if existing == nil || entry.updatedAt >= (existing?.updatedAt ?? 0) {
                entriesByPanelId[key.panelId] = entry
            }
        }
        self.entriesByPanelId = entriesByPanelId
    }
}

nonisolated struct SurfaceResumeBindingIndex: Sendable {
    static let empty = SurfaceResumeBindingIndex(bindingsByPanel: [:])

    typealias PanelKey = RestorableAgentSessionIndex.PanelKey

    private let bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]
    private let bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot]

    init(bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]) {
        self.bindingsByPanel = bindingsByPanel
        var bindingsByPanelId: [UUID: SurfaceResumeBindingSnapshot] = [:]
        for (key, binding) in bindingsByPanel {
            let existing = bindingsByPanelId[key.panelId]
            if existing == nil || binding.updatedAt >= (existing?.updatedAt ?? 0) {
                bindingsByPanelId[key.panelId] = binding
            }
        }
        self.bindingsByPanelId = bindingsByPanelId
    }

    func binding(workspaceId: UUID, panelId: UUID) -> SurfaceResumeBindingSnapshot? {
        bindingsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)] ?? bindingsByPanelId[panelId]
    }

    private static func loadProcessDetectedBindingsSynchronously(
        fileManager: FileManager = .default
    ) -> SurfaceResumeBindingIndex {
        let detectedBindings = processDetectedTmuxBindings(fileManager: fileManager)
        return SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
    }

    private static func loadIncludingProcessDetectedBindings(
        fileManager: FileManager = .default
    ) async -> SurfaceResumeBindingIndex {
        await Task.detached(priority: .utility) {
            loadProcessDetectedBindingsSynchronously(fileManager: fileManager)
        }.value
    }
}

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> ProcessDetectedResumeIndexes {
        await Task.detached(priority: .utility) {
            loadSynchronously(homeDirectory: homeDirectory, fileManager: fileManager)
        }.value
    }

    static func loadSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> ProcessDetectedResumeIndexes {
        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        let restorableAgentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots
        )
        let detectedBindings = SurfaceResumeBindingIndex.processDetectedTmuxBindings(
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        return ProcessDetectedResumeIndexes(
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
        )
    }
}

private extension CmuxTopProcessArguments {
    private func environmentUUID(forKey key: String) -> UUID? {
        guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }
}
