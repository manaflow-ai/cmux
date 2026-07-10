import Foundation
import CmuxGit
import CmuxFoundation
@testable import CmuxSidebarGit

/// A reader returning canned metadata, with an optional gate the test holds
/// closed to control exactly when a snapshot probe completes.
actor GatedMetadataReader: WorkspaceGitMetadataReading {
    private let metadata: GitWorkspaceMetadata
    private let gated: Bool
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var probedDirectories: [String] = []
    private(set) var probedTrackedPathEventGenerations: [GitTrackedPathEventGeneration?] = []

    init(metadata: GitWorkspaceMetadata, gated: Bool = false) {
        self.metadata = metadata
        self.gated = gated
        self.isOpen = !gated
    }

    func openGate() {
        isOpen = true
        while !gateWaiters.isEmpty {
            gateWaiters.removeFirst().resume()
        }
    }

    func waitForTrackedPathEventGenerationProbe(
        count minimumCount: Int = 1,
        maxYields: Int = 5_000
    ) async -> Bool {
        for _ in 0..<maxYields {
            if probedTrackedPathEventGenerations.count >= minimumCount {
                return true
            }
            await Task.yield()
        }
        return probedTrackedPathEventGenerations.count >= minimumCount
    }

    func waitForProbe(count minimumCount: Int = 1, maxYields: Int = 5_000) async -> Bool {
        for _ in 0..<maxYields {
            if probedDirectories.count >= minimumCount {
                return true
            }
            await Task.yield()
        }
        return probedDirectories.count >= minimumCount
    }

    func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata {
        await workspaceMetadata(for: directory, trackedPathEventGeneration: nil)
    }

    func workspaceMetadata(
        for directory: String,
        trackedPathEventGeneration: GitTrackedPathEventGeneration?
    ) async -> GitWorkspaceMetadata {
        probedDirectories.append(directory)
        probedTrackedPathEventGenerations.append(trackedPathEventGeneration)
        if !isOpen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isOpen {
                    continuation.resume()
                } else {
                    gateWaiters.append(continuation)
                }
            }
        }
        return metadata
    }
}

/// Records every call the git metadata service makes into the PR seam.
@MainActor
final class RecordingPullRequestProbing: PullRequestProbing {
    private struct SourceIdentity: Equatable {
        let directory: String
        let branch: String
    }

    private(set) var scheduledRefreshes: [(workspaceId: UUID, panelId: UUID, reason: String)] = []
    private(set) var clearedTrackingKeys: [(workspaceId: UUID, panelId: UUID)] = []
    private(set) var clearedTrackingWorkspaceIds: [UUID] = []
    var trackedPanelIdsByWorkspace: [UUID: Set<UUID>] = [:]
    private var sourceByKey: [WorkspaceGitProbeKey: SourceIdentity] = [:]
    private(set) var resetCount = 0

    func attach(host: any SidebarGitHosting) {}
    func scheduleWorkspacePullRequestRefresh(workspaceId: UUID, panelId: UUID, reason: String) {
        scheduledRefreshes.append((workspaceId, panelId, reason))
        trackedPanelIdsByWorkspace[workspaceId, default: []].insert(panelId)
    }
    func seedWorkspacePullRequestRefreshIfNeeded(
        workspaceId: UUID,
        panelId: UUID,
        directory: String,
        branch: String,
        reason: String
    ) {
        guard let normalizedBranch = GitMetadataService.normalizedBranchName(branch) else { return }
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        let source = SourceIdentity(
            directory: directory.normalizedGitProbeDirectory,
            branch: normalizedBranch
        )
        guard sourceByKey[key] != source else { return }
        sourceByKey[key] = source
        guard !PullRequestProbeService.shouldSkipLookup(branch: normalizedBranch) else { return }
        scheduleWorkspacePullRequestRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason
        )
    }
    func refreshTrackedWorkspacePullRequestsIfNeeded(reason: String) {}
    func sidebarPullRequestPollingSettingsDidChange() {}
    func handleWorkspacePullRequestCommandHint(workspaceId: UUID, panelId: UUID, action: String, target: String?) {}
    func clearWorkspacePullRequestTracking(workspaceId: UUID, panelId: UUID) {
        clearedTrackingKeys.append((workspaceId, panelId))
        trackedPanelIdsByWorkspace[workspaceId]?.remove(panelId)
        sourceByKey.removeValue(forKey: WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId))
    }
    func clearWorkspacePullRequestMetadata(workspaceId: UUID, panelId: UUID) {}
    func clearWorkspacePullRequestTracking(workspaceId: UUID) {
        clearedTrackingWorkspaceIds.append(workspaceId)
        trackedPanelIdsByWorkspace[workspaceId] = []
        sourceByKey = sourceByKey.filter { $0.key.workspaceId != workspaceId }
    }
    func resetWorkspacePullRequestRefreshState() {
        resetCount += 1
        trackedPanelIdsByWorkspace.removeAll()
        sourceByKey.removeAll()
    }
    func workspacePullRequestTrackedPanelIds(workspaceId: UUID) -> Set<UUID> {
        trackedPanelIdsByWorkspace[workspaceId] ?? []
    }
}

/// A `CommandRunning` that fails the test if any subprocess is spawned.
struct ForbiddenCommandRunner: CommandRunning {
    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        CommandResult(
            stdout: "",
            stderr: "unexpected subprocess: \(executable) \(arguments.joined(separator: " "))",
            exitStatus: 1,
            timedOut: false,
            executionError: "unexpected subprocess"
        )
    }
}

extension GitWorkspaceMetadata {
    static func repository(branch: String, isDirty: Bool = false) -> GitWorkspaceMetadata {
        GitWorkspaceMetadata(
            isRepository: true,
            branch: branch,
            isDirty: isDirty,
            indexSignature: "index",
            indexContentSignature: "content",
            headSignature: "head"
        )
    }

    static let nonRepository = GitWorkspaceMetadata(
        isRepository: false,
        branch: nil,
        isDirty: false,
        indexSignature: nil,
        indexContentSignature: nil,
        headSignature: nil
    )
}
