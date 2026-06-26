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
    private var probeWaiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var probedDirectories: [String] = []
    private(set) var probedTrackedPathEventGenerations: [UInt64?] = []

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

    func waitForTrackedPathEventGenerationProbe() async {
        if !probedTrackedPathEventGenerations.isEmpty {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !probedTrackedPathEventGenerations.isEmpty {
                continuation.resume()
            } else {
                probeWaiters.append(continuation)
            }
        }
    }

    func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata {
        await workspaceMetadata(for: directory, trackedPathEventGeneration: nil)
    }

    func workspaceMetadata(
        for directory: String,
        trackedPathEventGeneration: UInt64?
    ) async -> GitWorkspaceMetadata {
        probedDirectories.append(directory)
        probedTrackedPathEventGenerations.append(trackedPathEventGeneration)
        while !probeWaiters.isEmpty {
            probeWaiters.removeFirst().resume()
        }
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
    private(set) var scheduledRefreshes: [(workspaceId: UUID, panelId: UUID, reason: String)] = []
    private(set) var clearedTrackingKeys: [(workspaceId: UUID, panelId: UUID)] = []
    private(set) var clearedTrackingWorkspaceIds: [UUID] = []
    var trackedPanelIdsByWorkspace: [UUID: Set<UUID>] = [:]
    private(set) var resetCount = 0

    func attach(host: any SidebarGitHosting) {}
    func scheduleWorkspacePullRequestRefresh(workspaceId: UUID, panelId: UUID, reason: String) {
        scheduledRefreshes.append((workspaceId, panelId, reason))
        trackedPanelIdsByWorkspace[workspaceId, default: []].insert(panelId)
    }
    func refreshTrackedWorkspacePullRequestsIfNeeded(reason: String) {}
    func sidebarPullRequestPollingSettingsDidChange() {}
    func handleWorkspacePullRequestCommandHint(workspaceId: UUID, panelId: UUID, action: String, target: String?) {}
    func clearWorkspacePullRequestTracking(workspaceId: UUID, panelId: UUID) {
        clearedTrackingKeys.append((workspaceId, panelId))
        trackedPanelIdsByWorkspace[workspaceId]?.remove(panelId)
    }
    func clearWorkspacePullRequestMetadata(workspaceId: UUID, panelId: UUID) {}
    func clearWorkspacePullRequestTracking(workspaceId: UUID) {
        clearedTrackingWorkspaceIds.append(workspaceId)
        trackedPanelIdsByWorkspace[workspaceId] = []
    }
    func resetWorkspacePullRequestRefreshState() {
        resetCount += 1
        trackedPanelIdsByWorkspace.removeAll()
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
