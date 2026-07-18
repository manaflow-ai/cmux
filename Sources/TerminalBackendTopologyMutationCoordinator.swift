import CmuxTerminal
import CmuxTerminalBackend
import Foundation

struct TerminalBackendTopologyMutationSubmission: Equatable, Sendable {
    let requestID: UUID
}

enum TerminalBackendTopologyMutationSubmissionStatus: Equatable, Sendable {
    case queued
    case running
    case committed
    case failed
}

/// One fail-closed entrypoint for user-initiated terminal topology changes.
@MainActor
final class TerminalBackendTopologyMutationCoordinator {
    typealias FailureReporter = @MainActor (String) -> Void

    private let mutator: any TerminalBackendTopologyMutating
    private let failureReporter: FailureReporter
    private var mutationTail: Task<Void, Never>?
    private var submissionStatuses: [UUID: TerminalBackendTopologyMutationSubmissionStatus] = [:]
    private var submissionOrder: [UUID] = []
    private let maximumRetainedSubmissionStatuses = 256

    init(
        mutator: any TerminalBackendTopologyMutating,
        failureReporter: @escaping FailureReporter = { _ in }
    ) {
        self.mutator = mutator
        self.failureReporter = failureReporter
    }

    static let supportedMutations = Set(TerminalBackendTopologyMutation.allCases)

    /// Enqueues one daemon mutation and leaves local structure untouched until
    /// the canonical topology stream projects the committed transaction.
    @discardableResult
    func requestCreateWorkspace(
        name: String? = nil,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(.createWorkspace) { [mutator] in
            _ = try await mutator.createWorkspace(
                name: name,
                launch: launch,
                columns: columns,
                rows: rows
            )
        }
    }

    @discardableResult
    func requestCreateTerminalTab(
        in paneID: UUID,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(.attachSurface) { [mutator] in
            _ = try await mutator.createTerminalTab(
                in: CmuxTerminalBackend.PaneID(rawValue: paneID),
                launch: launch,
                columns: columns,
                rows: rows
            )
        }
    }

    @discardableResult
    func requestSplitPane(
        _ paneID: UUID,
        direction: BackendSplitDirection,
        launch: BackendTerminalLaunch = BackendTerminalLaunch(),
        columns: UInt16? = nil,
        rows: UInt16? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(.splitPane) { [mutator] in
            _ = try await mutator.splitPane(
                CmuxTerminalBackend.PaneID(rawValue: paneID),
                direction: direction,
                launch: launch,
                columns: columns,
                rows: rows
            )
        }
    }

    @discardableResult
    func requestSplitTab(
        _ surfaceID: UUID,
        around paneID: UUID,
        direction: BackendSplitDirection
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(.splitPane) { [mutator] in
            _ = try await mutator.splitTab(
                CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                around: CmuxTerminalBackend.PaneID(rawValue: paneID),
                direction: direction
            )
        }
    }

    @discardableResult
    func requestClosePane(_ paneID: UUID) -> TerminalBackendTopologyMutationSubmission {
        submit(.closePane) { [mutator] in
            try await mutator.closePane(CmuxTerminalBackend.PaneID(rawValue: paneID))
        }
    }

    @discardableResult
    func requestCloseWorkspace(_ workspaceID: UUID) -> TerminalBackendTopologyMutationSubmission {
        submit(.closeWorkspace) { [mutator] in
            try await mutator.closeWorkspace(
                CmuxTerminalBackend.WorkspaceID(rawValue: workspaceID)
            )
        }
    }

    @discardableResult
    func requestRenameWorkspace(
        _ workspaceID: UUID,
        name: String
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(.renameWorkspace) { [mutator] in
            try await mutator.renameWorkspace(
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
        submit(.renameSurface) { [mutator] in
            try await mutator.renameSurface(
                CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                name: name
            )
        }
    }

    @discardableResult
    func requestMoveTab(
        _ surfaceID: UUID,
        to paneID: UUID,
        index: Int
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(.moveTab) { [mutator] in
            try await mutator.moveTab(
                CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                to: CmuxTerminalBackend.PaneID(rawValue: paneID),
                index: index
            )
        }
    }

    @discardableResult
    func requestReorderTab(
        _ surfaceID: UUID,
        to index: Int
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(.reorderTab) { [mutator] in
            try await mutator.reorderTab(
                CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                to: index
            )
        }
    }

    @discardableResult
    func requestMoveWorkspace(
        _ workspaceID: UUID,
        to index: Int
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(.reorderWorkspace) { [mutator] in
            try await mutator.moveWorkspace(
                CmuxTerminalBackend.WorkspaceID(rawValue: workspaceID),
                to: index
            )
        }
    }

    @discardableResult
    func requestMoveTabToNewWorkspace(
        _ surfaceID: UUID,
        name: String?,
        index: Int? = nil
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(.createWorkspace) { [mutator] in
            _ = try await mutator.moveTabToNewWorkspace(
                CmuxTerminalBackend.SurfaceID(rawValue: surfaceID),
                name: name,
                index: index
            )
        }
    }

    @discardableResult
    func requestSetSplitRatio(
        around paneID: UUID,
        direction: BackendSplitDirection,
        ratio: Float
    ) -> TerminalBackendTopologyMutationSubmission {
        submit(.changeSplitRatio) { [mutator] in
            try await mutator.setSplitRatio(
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

    @discardableResult
    private func submit(
        _ mutation: TerminalBackendTopologyMutation,
        operation: @escaping @Sendable () async throws -> Void
    ) -> TerminalBackendTopologyMutationSubmission {
        let submission = TerminalBackendTopologyMutationSubmission(requestID: UUID())
        submissionStatuses[submission.requestID] = .queued
        submissionOrder.append(submission.requestID)
        if submissionOrder.count > maximumRetainedSubmissionStatuses {
            let removed = submissionOrder.removeFirst(
                submissionOrder.count - maximumRetainedSubmissionStatuses
            )
            for requestID in removed {
                submissionStatuses.removeValue(forKey: requestID)
            }
        }
        let previous = mutationTail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard let self, !Task.isCancelled else { return }
            self.submissionStatuses[submission.requestID] = .running
            do {
                try await operation()
                self.submissionStatuses[submission.requestID] = .committed
            } catch {
                self.submissionStatuses[submission.requestID] = .failed
                self.reportFailure(for: mutation)
            }
        }
        mutationTail = task
        return submission
    }
}
