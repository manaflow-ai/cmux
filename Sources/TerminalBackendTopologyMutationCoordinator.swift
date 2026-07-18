import CmuxTerminal
import CmuxTerminalBackend
import Foundation

struct TerminalBackendTopologyMutationSubmission: Equatable, Sendable {
    let requestID: UUID
    let workspaceID: UUID?
    let surfaceID: UUID?

    init(
        requestID: UUID,
        workspaceID: UUID? = nil,
        surfaceID: UUID? = nil
    ) {
        self.requestID = requestID
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
    }
}

enum TerminalBackendTopologyMutationSubmissionStatus: Equatable, Sendable {
    case queued
    case running
    case committed(BackendTopologyMutationReceipt)
    case projected(BackendTopologyMutationReceipt)
    case failed

    var isFinished: Bool {
        switch self {
        case .projected, .failed: true
        case .queued, .running, .committed: false
        }
    }
}

/// Serializes daemon mutations and distinguishes the daemon commit receipt
/// from successful projection of that receipt into Swift presentation state.
@MainActor
final class TerminalBackendTopologyMutationCoordinator {
    typealias FailureReporter = @MainActor (String) -> Void
    typealias ProjectionHandler = @MainActor (BackendTopologyMutationReceipt) -> Void
    typealias RequestFailureHandler = @MainActor () -> Void

    private struct SubmissionCallbacks {
        let projectionOwnerID: UUID?
        let projected: ProjectionHandler?
        let failed: RequestFailureHandler?
    }

    private let mutator: any TerminalBackendTopologyMutating
    private let failureReporter: FailureReporter
    private var mutationTail: Task<Void, Never>?
    private var submissionStatuses: [UUID: TerminalBackendTopologyMutationSubmissionStatus] = [:]
    private var submissionCallbacks: [UUID: SubmissionCallbacks] = [:]
    private var submissionOrder: [UUID] = []
    private var mutationTasks: [UUID: Task<Void, Never>] = [:]
    private var authorityGeneration: UInt64 = 0
    private var acceptsSubmissions = true
    private var latestProjectedSnapshot: TopologySnapshot?
    private var latestProjectedSnapshotsByOwner: [UUID: TopologySnapshot] = [:]
    private let maximumPendingSubmissions = 256
    private let maximumRetainedFinishedSubmissionStatuses = 256

    init(
        mutator: any TerminalBackendTopologyMutating,
        failureReporter: @escaping FailureReporter = { _ in }
    ) {
        self.mutator = mutator
        self.failureReporter = failureReporter
    }

    static let supportedMutations = Set(TerminalBackendTopologyMutation.allCases)

    /// Reserves stable identities synchronously, then leaves presentation
    /// creation to the matching canonical snapshot.
    @discardableResult
    func requestCreateWorkspace(
        workspaceID: UUID = UUID(),
        surfaceID: UUID = UUID(),
        name: String? = nil,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil,
        projectionOwnerID: UUID? = nil,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .createWorkspace,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            projectionOwnerID: projectionOwnerID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.createWorkspace(
                requestID: requestID,
                workspaceID: CmuxTerminalBackend.WorkspaceID(rawValue: workspaceID),
                surfaceID: CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                name: name,
                launch: launch,
                columns: columns,
                rows: rows
            ).receipt
        }
    }

    @discardableResult
    func requestCreateTerminalTab(
        surfaceID: UUID = UUID(),
        in paneID: UUID,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .attachSurface,
            surfaceID: surfaceID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.createTerminalTab(
                requestID: requestID,
                surfaceID: CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                in: CmuxTerminalBackend.PaneID(rawValue: paneID),
                launch: launch,
                columns: columns,
                rows: rows
            ).receipt
        }
    }

    @discardableResult
    func requestCreateBrowserWorkspace(
        workspaceID: UUID = UUID(),
        surfaceID: UUID = UUID(),
        name: String? = nil,
        url: URL,
        columns: UInt16? = nil,
        rows: UInt16? = nil,
        projectionOwnerID: UUID? = nil,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .createWorkspace,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            projectionOwnerID: projectionOwnerID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.createBrowserWorkspace(
                requestID: requestID,
                workspaceID: CmuxTerminalBackend.WorkspaceID(rawValue: workspaceID),
                surfaceID: CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                name: name,
                url: url,
                columns: columns,
                rows: rows
            ).receipt
        }
    }

    @discardableResult
    func requestCreateBrowserTab(
        surfaceID: UUID = UUID(),
        in paneID: UUID,
        url: URL,
        columns: UInt16? = nil,
        rows: UInt16? = nil,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .attachSurface,
            surfaceID: surfaceID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.createBrowserTab(
                requestID: requestID,
                surfaceID: CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                in: CmuxTerminalBackend.PaneID(rawValue: paneID),
                url: url,
                columns: columns,
                rows: rows
            ).receipt
        }
    }

    @discardableResult
    func requestSplitBrowserPane(
        surfaceID: UUID = UUID(),
        _ paneID: UUID,
        direction: BackendSplitDirection,
        initialRatio: Float = 0.5,
        url: URL,
        columns: UInt16? = nil,
        rows: UInt16? = nil,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .splitPane,
            surfaceID: surfaceID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.splitBrowserPane(
                requestID: requestID,
                surfaceID: CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                CmuxTerminalBackend.PaneID(rawValue: paneID),
                direction: direction,
                initialRatio: initialRatio,
                url: url,
                columns: columns,
                rows: rows
            ).receipt
        }
    }

    @discardableResult
    func requestMaterializeTerminal(
        workspaceID: UUID,
        surfaceID: UUID,
        launch: BackendTerminalLaunch,
        columns: UInt16? = nil,
        rows: UInt16? = nil,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .attachSurface,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.materializeTerminal(
                requestID: requestID,
                workspaceID: CmuxTerminalBackend.WorkspaceID(rawValue: workspaceID),
                surfaceID: CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                launch: launch,
                columns: columns,
                rows: rows
            ).receipt
        }
    }

    /// Materializes a parser/renderer endpoint with no daemon PTY or child.
    @discardableResult
    func requestMaterializeExternalTerminal(
        workspaceID: UUID,
        surfaceID: UUID,
        columns: UInt16,
        rows: UInt16,
        noReflow: Bool,
        provenance: CanonicalExternalTerminalProvenance,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .attachSurface,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.materializeExternalTerminal(
                requestID: requestID,
                workspaceID: CmuxTerminalBackend.WorkspaceID(rawValue: workspaceID),
                surfaceID: CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                columns: columns,
                rows: rows,
                noReflow: noReflow,
                provenance: provenance
            ).receipt
        }
    }

    /// Creates a canonical workspace and its first parser-only surface in one
    /// revision, so remote mirrors never allocate a placeholder PTY.
    @discardableResult
    func requestCreateExternalWorkspace(
        workspaceID: UUID = UUID(),
        surfaceID: UUID = UUID(),
        columns: UInt16,
        rows: UInt16,
        noReflow: Bool,
        provenance: CanonicalExternalTerminalProvenance,
        producerSource: BackendRemoteTmuxProducerSource,
        projectionOwnerID: UUID? = nil,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .createWorkspace,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            projectionOwnerID: projectionOwnerID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.newExternalWorkspace(
                requestID: requestID,
                workspaceID: CmuxTerminalBackend.WorkspaceID(rawValue: workspaceID),
                surfaceID: CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                columns: columns,
                rows: rows,
                noReflow: noReflow,
                provenance: provenance,
                producerSource: producerSource
            ).receipt
        }
    }

    @discardableResult
    func requestRespawnTerminal(
        surfaceID: UUID,
        launch: BackendTerminalLaunch,
        columns: UInt16? = nil,
        rows: UInt16? = nil,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .attachSurface,
            surfaceID: surfaceID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.respawnTerminal(
                requestID: requestID,
                surfaceID: CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                launch: launch,
                columns: columns,
                rows: rows
            ).receipt
        }
    }

    @discardableResult
    func requestSplitPane(
        surfaceID: UUID = UUID(),
        _ paneID: UUID,
        direction: BackendSplitDirection,
        initialRatio: Float = 0.5,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .splitPane,
            surfaceID: surfaceID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.splitPane(
                requestID: requestID,
                surfaceID: CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                CmuxTerminalBackend.PaneID(rawValue: paneID),
                direction: direction,
                initialRatio: initialRatio,
                launch: launch,
                columns: columns,
                rows: rows
            ).receipt
        }
    }

    @discardableResult
    func requestSplitTab(
        _ surfaceID: UUID,
        around paneID: UUID,
        direction: BackendSplitDirection,
        initialRatio: Float = 0.5,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .splitPane,
            surfaceID: surfaceID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.splitTab(
                requestID: requestID,
                CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                around: CmuxTerminalBackend.PaneID(rawValue: paneID),
                direction: direction,
                initialRatio: initialRatio
            ).receipt
        }
    }

    @discardableResult
    func requestClosePane(
        _ paneID: UUID,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .closePane,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.closePane(
                requestID: requestID,
                CmuxTerminalBackend.PaneID(rawValue: paneID)
            )
        }
    }

    @discardableResult
    func requestCloseSurface(
        _ surfaceID: UUID,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .closeTerminal,
            surfaceID: surfaceID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.closeSurface(
                requestID: requestID,
                CmuxTerminalBackend.SurfaceID(rawValue: surfaceID)
            )
        }
    }

    @discardableResult
    func requestCloseWorkspace(
        _ workspaceID: UUID,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .closeWorkspace,
            workspaceID: workspaceID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.closeWorkspace(
                requestID: requestID,
                CmuxTerminalBackend.WorkspaceID(rawValue: workspaceID)
            )
        }
    }

    @discardableResult
    func requestRenameWorkspace(
        _ workspaceID: UUID,
        name: String
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(.renameWorkspace, workspaceID: workspaceID) { [mutator] requestID in
            try await mutator.renameWorkspace(
                requestID: requestID,
                CmuxTerminalBackend.WorkspaceID(rawValue: workspaceID),
                name: name
            )
        }
    }

    @discardableResult
    func requestRenameSurface(
        _ surfaceID: UUID,
        name: String
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(.renameSurface, surfaceID: surfaceID) { [mutator] requestID in
            try await mutator.renameSurface(
                requestID: requestID,
                CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                name: name
            )
        }
    }

    @discardableResult
    func requestMoveTab(
        _ surfaceID: UUID,
        to paneID: UUID,
        index: Int,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .moveTab,
            surfaceID: surfaceID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.moveTab(
                requestID: requestID,
                CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                to: CmuxTerminalBackend.PaneID(rawValue: paneID),
                index: index
            )
        }
    }

    @discardableResult
    func requestReorderTabs(
        in paneID: UUID,
        surfaceIDs: [UUID],
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .reorderTab,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.reorderTabs(
                requestID: requestID,
                in: CmuxTerminalBackend.PaneID(rawValue: paneID),
                surfaceIDs: surfaceIDs.map(CmuxTerminalBackend.SurfaceID.init(rawValue:))
            )
        }
    }

    @discardableResult
    func requestReorderWorkspaces(
        _ workspaceIDs: [UUID],
        onProjected: ProjectionHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(.reorderWorkspace, onProjected: onProjected) { [mutator] requestID in
            try await mutator.reorderWorkspaces(
                requestID: requestID,
                workspaceIDs.map(CmuxTerminalBackend.WorkspaceID.init(rawValue:))
            )
        }
    }

    @discardableResult
    func requestMoveTabToNewWorkspace(
        _ surfaceID: UUID,
        workspaceID: UUID = UUID(),
        name: String?,
        index: Int? = nil,
        projectionOwnerID: UUID? = nil,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .createWorkspace,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            projectionOwnerID: projectionOwnerID,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.moveTabToNewWorkspace(
                requestID: requestID,
                CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                workspaceID: CmuxTerminalBackend.WorkspaceID(rawValue: workspaceID),
                name: name,
                index: index
            ).receipt
        }
    }

    @discardableResult
    func requestSetSplitRatio(
        around paneID: UUID,
        direction: BackendSplitDirection,
        ratio: Float,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(
            .changeSplitRatio,
            onProjected: onProjected,
            onFailure: onFailure
        ) { [mutator] requestID in
            try await mutator.setSplitRatio(
                requestID: requestID,
                around: CmuxTerminalBackend.PaneID(rawValue: paneID),
                direction: direction,
                ratio: ratio
            )
        }
    }

    @discardableResult
    func requestReparent(
        _ panel: TerminalPanel,
        to workspaceID: UUID
    ) -> Bool {
        guard panel.surface.requestCanonicalReparent(to: workspaceID).accepted else {
            reportFailure(for: .reparentTerminal)
            return false
        }
        return true
    }

    @discardableResult
    func requestClose(_ panel: TerminalPanel) -> Bool {
        guard panel.surface.requestCanonicalClose().accepted else {
            reportFailure(for: .closeTerminal)
            return false
        }
        return true
    }

    @discardableResult
    func reject(_ mutation: TerminalBackendTopologyMutation) -> Bool {
        reportFailure(for: mutation)
        return false
    }

    func rejectionMessage(for mutation: TerminalBackendTopologyMutation) -> String {
        String(
            localized: "terminalBackend.topology.mutationUnavailable",
            defaultValue: "The terminal backend cannot commit this layout change yet (\(mutation.rawValue)). Your current layout was left unchanged."
        )
    }

    func reportFailure(for mutation: TerminalBackendTopologyMutation) {
        failureReporter(rejectionMessage(for: mutation))
    }

    func submissionStatus(
        requestID: UUID
    ) -> TerminalBackendTopologyMutationSubmissionStatus? {
        submissionStatuses[requestID]
    }

    /// Called only after a topology projection transaction has finalized.
    func canonicalProjectionDidInstall(
        _ snapshot: TopologySnapshot,
        presentationID: UUID? = nil
    ) {
        if let latestProjectedSnapshot,
           latestProjectedSnapshot.authority != snapshot.authority {
            acceptsSubmissions = false
            latestProjectedSnapshotsByOwner.removeAll(keepingCapacity: true)
            failUnfinishedSubmissionsForAuthorityChange()
        } else if submissionOrder.contains(where: { requestID in
            guard case .committed(let receipt) = submissionStatuses[requestID] else {
                return false
            }
            return receipt.authority != snapshot.authority
        }) {
            acceptsSubmissions = false
            latestProjectedSnapshotsByOwner.removeAll(keepingCapacity: true)
            failUnfinishedSubmissionsForAuthorityChange()
        }
        let previousForPresentation = presentationID.flatMap {
            latestProjectedSnapshotsByOwner[$0]
        }
        if let previousForPresentation,
           previousForPresentation.authority == snapshot.authority,
           previousForPresentation.revision >= snapshot.revision {
            return
        }
        if presentationID == nil,
           let latestProjectedSnapshot,
           latestProjectedSnapshot.authority == snapshot.authority,
           latestProjectedSnapshot.revision >= snapshot.revision {
            return
        }
        if let presentationID {
            latestProjectedSnapshotsByOwner[presentationID] = snapshot
        }
        if latestProjectedSnapshot?.authority != snapshot.authority
            || latestProjectedSnapshot?.revision ?? 0 < snapshot.revision {
            latestProjectedSnapshot = snapshot
        }
        acceptsSubmissions = true
        for requestID in submissionOrder {
            guard case .committed(let receipt) = submissionStatuses[requestID],
                  snapshotContains(receipt, in: snapshot) else {
                continue
            }
            if let projectionOwnerID = submissionCallbacks[requestID]?.projectionOwnerID,
               projectionOwnerID != presentationID {
                continue
            }
            finishProjection(requestID: requestID, receipt: receipt)
        }
        trimFinishedSubmissionHistory()
    }

    /// Invalidates requests admitted against a daemon generation that is no
    /// longer authoritative. The generation fence covers transports that may
    /// still finish an RPC after their task is cancelled.
    func authorityDidDisconnect(_ authority: BackendAuthority) {
        if let latestProjectedSnapshot,
           latestProjectedSnapshot.authority != authority {
            return
        }
        latestProjectedSnapshot = nil
        latestProjectedSnapshotsByOwner.removeAll(keepingCapacity: true)
        acceptsSubmissions = false
        failUnfinishedSubmissionsForAuthorityChange()
    }

    @discardableResult
    private func submit(
        _ mutation: TerminalBackendTopologyMutation,
        workspaceID: UUID? = nil,
        surfaceID: UUID? = nil,
        projectionOwnerID: UUID? = nil,
        onProjected: ProjectionHandler? = nil,
        onFailure: RequestFailureHandler? = nil,
        operation: @escaping @Sendable (UUID) async throws -> BackendTopologyMutationReceipt
    ) -> TerminalBackendTopologyMutationSubmission {
        let submission = TerminalBackendTopologyMutationSubmission(
            requestID: UUID(),
            workspaceID: workspaceID,
            surfaceID: surfaceID
        )
        trimFinishedSubmissionHistory()
        let pendingSubmissionCount = submissionStatuses.values.reduce(into: 0) {
            if !$1.isFinished { $0 += 1 }
        }
        guard acceptsSubmissions,
              pendingSubmissionCount < maximumPendingSubmissions else {
            submissionStatuses[submission.requestID] = .failed
            submissionOrder.append(submission.requestID)
            onFailure?()
            failureReporter(rejectionMessage(for: mutation))
            trimFinishedSubmissionHistory()
            return submission
        }
        submissionStatuses[submission.requestID] = .queued
        submissionCallbacks[submission.requestID] = SubmissionCallbacks(
            projectionOwnerID: projectionOwnerID,
            projected: onProjected,
            failed: onFailure
        )
        submissionOrder.append(submission.requestID)
        trimFinishedSubmissionHistory()

        let previous = mutationTail
        let generation = authorityGeneration
        let task = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self,
                  !Task.isCancelled,
                  generation == self.authorityGeneration,
                  self.submissionStatuses[submission.requestID] == .queued else {
                return
            }
            self.submissionStatuses[submission.requestID] = .running
            do {
                let receipt = try await operation(submission.requestID)
                guard !Task.isCancelled,
                      generation == self.authorityGeneration,
                      self.submissionStatuses[submission.requestID] == .running else {
                    return
                }
                self.submissionStatuses[submission.requestID] = .committed(receipt)
                let projectionOwnerID = self.submissionCallbacks[
                    submission.requestID
                ]?.projectionOwnerID
                let snapshot = projectionOwnerID.flatMap {
                    self.latestProjectedSnapshotsByOwner[$0]
                } ?? (projectionOwnerID == nil ? self.latestProjectedSnapshot : nil)
                if let snapshot,
                   self.snapshotContains(receipt, in: snapshot) {
                    self.finishProjection(
                        requestID: submission.requestID,
                        receipt: receipt
                    )
                }
            } catch {
                guard generation == self.authorityGeneration,
                      self.submissionStatuses[submission.requestID] == .running else {
                    return
                }
                self.submissionStatuses[submission.requestID] = .failed
                let callbacks = self.submissionCallbacks.removeValue(
                    forKey: submission.requestID
                )
                callbacks?.failed?()
                self.reportFailure(for: mutation)
            }
            self.mutationTasks.removeValue(forKey: submission.requestID)
            self.trimFinishedSubmissionHistory()
        }
        mutationTail = task
        mutationTasks[submission.requestID] = task
        return submission
    }

    private func snapshotContains(
        _ receipt: BackendTopologyMutationReceipt,
        in snapshot: TopologySnapshot
    ) -> Bool {
        snapshot.authority == receipt.authority && snapshot.revision >= receipt.revision
    }

    private func finishProjection(
        requestID: UUID,
        receipt: BackendTopologyMutationReceipt
    ) {
        guard case .committed = submissionStatuses[requestID] else { return }
        submissionStatuses[requestID] = .projected(receipt)
        let callbacks = submissionCallbacks.removeValue(forKey: requestID)
        callbacks?.projected?(receipt)
    }

    private func failUnfinishedSubmissionsForAuthorityChange() {
        authorityGeneration &+= 1
        mutationTail = nil
        let tasks = Array(mutationTasks.values)
        mutationTasks.removeAll(keepingCapacity: true)
        for task in tasks {
            task.cancel()
        }

        var failureHandlers: [RequestFailureHandler] = []
        var failedAnySubmission = false
        for requestID in submissionOrder {
            guard let status = submissionStatuses[requestID], !status.isFinished else {
                continue
            }
            failedAnySubmission = true
            submissionStatuses[requestID] = .failed
            if let callback = submissionCallbacks.removeValue(forKey: requestID)?.failed {
                failureHandlers.append(callback)
            }
        }
        guard failedAnySubmission else { return }
        for handler in failureHandlers {
            handler()
        }
        failureReporter(String(
            localized: "terminalBackend.topology.mutationAuthorityChanged",
            defaultValue: "The terminal backend restarted before a layout change reached the screen. Retry the change after the layout reconnects."
        ))
        trimFinishedSubmissionHistory()
    }

    private func trimFinishedSubmissionHistory() {
        let finishedCount = submissionOrder.reduce(into: 0) { count, requestID in
            if submissionStatuses[requestID]?.isFinished == true { count += 1 }
        }
        guard finishedCount > maximumRetainedFinishedSubmissionStatuses else { return }
        var removableCount = finishedCount - maximumRetainedFinishedSubmissionStatuses
        var retained: [UUID] = []
        retained.reserveCapacity(submissionOrder.count)
        for requestID in submissionOrder {
            if removableCount > 0,
               submissionStatuses[requestID]?.isFinished == true {
                submissionStatuses.removeValue(forKey: requestID)
                submissionCallbacks.removeValue(forKey: requestID)
                removableCount -= 1
            } else {
                retained.append(requestID)
            }
        }
        submissionOrder = retained
    }
}
