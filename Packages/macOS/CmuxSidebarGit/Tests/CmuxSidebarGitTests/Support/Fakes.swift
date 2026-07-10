import Foundation
import CmuxGit
import CmuxFoundation
@testable import CmuxSidebarGit

/// A reader returning canned metadata, with an optional gate the test holds
/// closed to control exactly when a snapshot probe completes.
actor GatedMetadataReader: WorkspaceGitMetadataReading {
    private struct ProbeWaiter {
        let minimumCount: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let metadata: GitWorkspaceMetadata
    private let gated: Bool
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var probeWaitersByID: [UUID: ProbeWaiter] = [:]
    private var isOpen = false
    private(set) var probedDirectories: [String] = []
    private(set) var probedSnapshotRequests: [GitTrackedChangesSnapshotRequest?] = []

    var probedTrackedPathEventGenerations: [GitTrackedPathEventGeneration?] {
        probedSnapshotRequests.map { request in
            switch request {
            case .fallbackRound:
                nil
            case .watcherEvent(_, let eventID):
                eventID
            case nil:
                nil
            }
        }
    }

    var probedFallbackRoundIDs: [GitFallbackRoundID] {
        probedSnapshotRequests.compactMap { request in
            guard case .fallbackRound(let id, _) = request else { return nil }
            return id
        }
    }

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

    nonisolated func waitForTrackedPathEventGenerationProbe(
        count minimumCount: Int = 1,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await waitForProbeArrival(count: minimumCount, timeout: timeout)
    }

    nonisolated func waitForProbe(
        count minimumCount: Int = 1,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        await waitForProbeArrival(count: minimumCount, timeout: timeout)
    }

    private nonisolated func waitForProbeArrival(
        count minimumCount: Int,
        timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForProbeArrival(count: minimumCount)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return false
                }
            }
            let didArrive = await group.next() ?? false
            group.cancelAll()
            return didArrive
        }
    }

    private func waitForProbeArrival(count minimumCount: Int) async -> Bool {
        if probedDirectories.count >= minimumCount {
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                probeWaitersByID[waiterID] = ProbeWaiter(
                    minimumCount: minimumCount,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelProbeWaiter(waiterID)
            }
        }
    }

    private func cancelProbeWaiter(_ waiterID: UUID) {
        probeWaitersByID.removeValue(forKey: waiterID)?.continuation.resume(returning: false)
    }

    private func resumeSatisfiedProbeWaiters() {
        let probeCount = probedDirectories.count
        let satisfiedWaiterIDs = probeWaitersByID.compactMap { id, waiter in
            waiter.minimumCount <= probeCount ? id : nil
        }
        for waiterID in satisfiedWaiterIDs {
            probeWaitersByID.removeValue(forKey: waiterID)?.continuation.resume(returning: true)
        }
    }

    func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata {
        await workspaceMetadata(for: directory, snapshotRequest: nil)
    }

    func workspaceMetadata(
        for directory: String,
        snapshotRequest: GitTrackedChangesSnapshotRequest?
    ) async -> GitWorkspaceMetadata {
        probedDirectories.append(directory)
        probedSnapshotRequests.append(snapshotRequest)
        resumeSatisfiedProbeWaiters()
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
