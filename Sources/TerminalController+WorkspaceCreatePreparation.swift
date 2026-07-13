import Foundation

extension TerminalController {
    struct WorkspaceCreatePreparation {
        let tabManager: TabManager
        let operationID: UUID?
        let idempotencyCache: WorkspaceCreateIdempotencyCache
    }

    enum WorkspaceCreatePreparationOutcome {
        case failure(V2CallResult)
        case existing(TaskCreateWorkspaceResolution)
        case completed(tabManager: TabManager, operationID: UUID)
        case ready(WorkspaceCreatePreparation)
    }

    enum TaskCreateOperationResolution {
        case live(TaskCreateWorkspaceResolution)
        case completed
    }

    func v2PrepareWorkspaceCreate(
        params: [String: Any],
        tabManager resolvedTabManager: TabManager?,
        taskCreateCandidates: [TaskCreateWorkspaceCandidate]?,
        idempotencyCache suppliedIdempotencyCache: WorkspaceCreateIdempotencyCache?
    ) -> WorkspaceCreatePreparationOutcome {
        let operationID: UUID?
        if v2HasNonNullParam(params, "operation_id") {
            guard let parsed = v2UUID(params, "operation_id") else {
                return .failure(
                    .err(code: "invalid_params", message: "operation_id must be a UUID", data: nil)
                )
            }
            operationID = parsed
        } else {
            operationID = nil
        }
        guard let tabManager = resolvedTabManager ?? v2ResolveTabManager(params: params) else {
            return .failure(.err(code: "unavailable", message: "TabManager not available", data: nil))
        }
        let idempotencyCache = suppliedIdempotencyCache ?? workspaceCreateIdempotencyCache

        let candidates = taskCreateCandidates ?? taskCreateWorkspaceCandidates(requested: tabManager)
        if let operationID {
            switch taskCreateOperationResolution(
                operationID: operationID,
                candidates: candidates,
                idempotencyCache: idempotencyCache
            ) {
            case let .live(resolution):
                return .existing(resolution)
            case .completed:
                return .completed(tabManager: tabManager, operationID: operationID)
            case nil:
                break
            }
        }
        return .ready(WorkspaceCreatePreparation(
            tabManager: tabManager,
            operationID: operationID,
            idempotencyCache: idempotencyCache
        ))
    }

    func taskCreateWorkspaceCandidates(requested tabManager: TabManager) -> [TaskCreateWorkspaceCandidate] {
        var candidates = [TaskCreateWorkspaceCandidate(
            tabManager: tabManager,
            windowID: v2ResolveWindowId(tabManager: tabManager)
        )]
        candidates.append(contentsOf: AppDelegate.shared?.scriptableMainWindows().map {
            TaskCreateWorkspaceCandidate(tabManager: $0.tabManager, windowID: $0.windowId)
        } ?? [])
        return candidates
    }

    func taskCreateOperationResolution(
        operationID: UUID,
        candidates: [TaskCreateWorkspaceCandidate],
        idempotencyCache: WorkspaceCreateIdempotencyCache
    ) -> TaskCreateOperationResolution? {
        let resolution = Self.resolveTaskCreateWorkspace(
            operationID: operationID,
            cachedWorkspaceID: idempotencyCache.workspaceID(for: operationID),
            candidates: candidates
        )
        if let resolution {
            idempotencyCache.record(
                operationID: operationID,
                workspaceID: resolution.workspace.id
            )
            return .live(resolution)
        }
        return idempotencyCache.containsCompletedOperation(operationID) ? .completed : nil
    }

    static func resolveTaskCreateWorkspace(
        operationID: UUID,
        cachedWorkspaceID: UUID?,
        candidates: [TaskCreateWorkspaceCandidate]
    ) -> TaskCreateWorkspaceResolution? {
        var seen: Set<ObjectIdentifier> = []
        let uniqueCandidates = candidates.filter { seen.insert(ObjectIdentifier($0.tabManager)).inserted }
        if let cachedWorkspaceID {
            for candidate in uniqueCandidates {
                if let workspace = candidate.tabManager.tabs.first(where: { $0.id == cachedWorkspaceID }),
                   workspace.taskCreateOperationID == operationID {
                    return TaskCreateWorkspaceResolution(workspace: workspace, candidate: candidate)
                }
            }
        }
        for candidate in uniqueCandidates {
            if let workspace = candidate.tabManager.tabs.first(where: { $0.taskCreateOperationID == operationID }) {
                return TaskCreateWorkspaceResolution(workspace: workspace, candidate: candidate)
            }
        }
        return nil
    }
}
