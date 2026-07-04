import Foundation

struct RestorableAgentSnapshotIndex: Sendable {
    static let empty = RestorableAgentSnapshotIndex(stale: .empty)

    private let index: RestorableAgentSessionIndex
    private let trustsLiveProcess: Bool

    init(stale index: RestorableAgentSessionIndex) {
        self.index = index
        self.trustsLiveProcess = false
    }

    private init(freshlyLoaded index: RestorableAgentSessionIndex) {
        self.index = index
        self.trustsLiveProcess = true
    }

    static func freshlyLoaded(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSnapshotIndex {
        RestorableAgentSnapshotIndex(freshlyLoaded: RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ))
    }

    static func freshlyLoaded(
        homeDirectory: String,
        fileManager: FileManager,
        registry: CmuxVaultAgentRegistry,
        detectedSnapshots: [RestorableAgentSessionIndex.PanelKey: RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry],
        processArgumentsProvider: (Int) -> CmuxTopProcessArguments? = {
            CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: $0)
        }
    ) -> RestorableAgentSnapshotIndex {
        RestorableAgentSnapshotIndex(freshlyLoaded: RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots,
            processArgumentsProvider: processArgumentsProvider
        ))
    }

    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        index.snapshot(workspaceId: workspaceId, panelId: panelId)
    }

    func hasTrustedLiveProcess(workspaceId: UUID, panelId: UUID) -> Bool {
        guard trustsLiveProcess else { return false }
        return index.hasLiveProcess(workspaceId: workspaceId, panelId: panelId)
    }
}
