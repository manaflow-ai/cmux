import Combine
import CmuxCore
import CmuxWorkspaces
import Foundation
import CmuxSidebar
import SwiftUI

private struct SidebarPanelObservationState: Equatable {
    let panelIds: [UUID]

    init(panels: [UUID: any Panel]) {
        panelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
    }
}

extension View {
    /// Observes row-affecting workspace publishers above the lazy-list boundary.
    ///
    /// Each task retains the workspace identity that produced a change, so a
    /// status/metadata/title update rebuilds one immutable row projection
    /// instead of walking every workspace. The initial CombineLatest value is
    /// intentionally delivered: it closes the gap between the owner's first
    /// snapshot and subscription setup, while the snapshot equality guard makes
    /// an unchanged initial value a no-op.
    func sidebarWorkspaceObservations(
        ids: [UUID],
        workspaces: [Workspace],
        debouncedInterval: DispatchQueue.SchedulerTimeType.Stride,
        onChange: @MainActor @escaping (UUID) -> Void
    ) -> some View {
        task(id: ids) { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for (id, workspace) in zip(ids, workspaces) {
                    let immediateChanges = workspace.sidebarImmediateObservationPublisher
                        .values
                    let debouncedChanges = workspace.sidebarObservationPublisher
                        // DispatchQueue.main, not RunLoop.main: the RunLoop
                        // scheduler delivers only in the DEFAULT runloop mode,
                        // so modal panels (rename alert), context menus, and
                        // drag tracking stalled every sidebar row update until
                        // the mode unwound. Main-queue delivery is mode-agnostic.
                        .receive(on: DispatchQueue.main)
                        .debounce(for: debouncedInterval, scheduler: DispatchQueue.main)
                        .values
                    group.addTask { @MainActor in
                        for await _ in immediateChanges {
                            if Task.isCancelled { break }
                            onChange(id)
                        }
                    }
                    group.addTask { @MainActor in
                        for await _ in debouncedChanges {
                            if Task.isCancelled { break }
                            onChange(id)
                        }
                    }
                }
            }
        }
    }

    func sidebarAgentRuntimeObservation(
        id: UUID,
        model: WorkspaceSidebarAgentRuntimeObservationModel,
        onChange: @MainActor @escaping () -> Void
    ) -> some View {
        task(id: id) { @MainActor in
            for await _ in model.changes() {
                if Task.isCancelled { break }
                onChange()
            }
        }
    }

    func sidebarProcessTitleObservation(
        id: UUID,
        model: WorkspaceSidebarProcessTitleObservationModel,
        onChange: @MainActor @escaping () -> Void
    ) -> some View {
        task(id: id) { @MainActor in
            for await _ in model.changes() {
                if Task.isCancelled { break }
                onChange()
            }
        }
    }

    func sidebarProcessTitleObservations(
        ids: [UUID],
        models: [WorkspaceSidebarProcessTitleObservationModel],
        onChange: @MainActor @escaping () -> Void
    ) -> some View {
        task(id: ids) { @MainActor in
            let aggregateObservation = WorkspaceSidebarProcessTitleObservationModel(
                settleInterval: WorkspaceSidebarProcessTitleObservationModel.extensionSidebarAggregateInterval
            )
            let aggregateChanges = aggregateObservation.changes()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    for await _ in aggregateChanges {
                        if Task.isCancelled { break }
                        onChange()
                    }
                }
                for model in models {
                    let changes = model.changes()
                    group.addTask { @MainActor in
                        for await _ in changes {
                            if Task.isCancelled { break }
                            aggregateObservation.processTitleDidChange()
                        }
                    }
                }
            }
        }
    }

    /// Observes every default-sidebar workspace above the lazy row boundary.
    /// The callback identifies the changed workspace so the owner can rebuild
    /// its immutable projection without mounting an observation task per row.
    func sidebarProcessTitleObservations(
        ids: [UUID],
        models: [WorkspaceSidebarProcessTitleObservationModel],
        onChange: @MainActor @escaping (UUID) -> Void
    ) -> some View {
        task(id: ids) { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for (id, model) in zip(ids, models) {
                    let changes = model.changes()
                    group.addTask { @MainActor in
                        for await _ in changes {
                            if Task.isCancelled { break }
                            onChange(id)
                        }
                    }
                }
            }
        }
    }

    /// Agent-runtime counterpart to ``sidebarProcessTitleObservations(ids:models:onChange:)``.
    func sidebarAgentRuntimeObservations(
        ids: [UUID],
        models: [WorkspaceSidebarAgentRuntimeObservationModel],
        onChange: @MainActor @escaping (UUID) -> Void
    ) -> some View {
        task(id: ids) { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for (id, model) in zip(ids, models) {
                    let changes = model.changes()
                    group.addTask { @MainActor in
                        for await _ in changes {
                            if Task.isCancelled { break }
                            onChange(id)
                        }
                    }
                }
            }
        }
    }
}

private struct SidebarImmediateObservationState: Equatable {
    let customTitle: String?
    let customDescription: String?
    let isPinned: Bool
    let customColor: String?
    let latestConversationMessage: String?
    let latestSubmittedMessage: String?
    let latestSubmittedAt: Date?
    let taskStatusOverride: WorkspaceTaskStatusOverride?
    let statusHidden: Bool
    let checklist: [WorkspaceChecklistItem]
}

private struct SidebarObservationState: Equatable {
    let currentDirectory: String
    let extensionSidebarProjectRootPath: String?
    let panels: SidebarPanelObservationState
    let panelDirectories: [UUID: String]
    let panelDirectoryDisplayLabels: [UUID: String]
    let directoryChangeRevision: UInt64
    let statusEntries: [String: SidebarStatusEntry]
    let metadataBlocks: [String: SidebarMetadataBlock]
    let logEntries: [SidebarLogEntry]
    let progress: SidebarProgressState?
    let gitBranch: SidebarGitBranchState?
    let panelGitBranches: [UUID: SidebarGitBranchState]
    let pullRequest: SidebarPullRequestState?
    let panelPullRequests: [UUID: SidebarPullRequestState]
    let remoteConfiguration: WorkspaceRemoteConfiguration?
    let remoteConnectionState: WorkspaceRemoteConnectionState
    let remoteConnectionDetail: String?
    let activeRemoteTerminalSessionCount: Int
    let listeningPorts: [Int]
    let browserMediaActivity: BrowserMediaActivity
}

extension Workspace {
    // User-owned sidebar fields keep a synchronous leading edge. Automatic
    // process titles settle separately: agent TUIs can animate their terminal
    // title at 10 Hz, and per-workspace burst coalescing cannot reduce changes
    // spaced farther apart than its window. Waiting for the title to settle
    // prevents those frames from continuously invalidating LazyVStack rows,
    // and the settle model's deferral deadline still republishes during
    // sustained churn so a row's title cannot stay stale until the agent
    // goes quiet. See https://github.com/manaflow-ai/cmux/issues/5570.
    static let sidebarImmediateObservationCoalesceInterval: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(50)
    func makeSidebarImmediateObservationPublisher() -> AnyPublisher<Void, Never> {
        let workspaceFields = Publishers.CombineLatest4(
            $customTitle,
            $customDescription,
            $isPinned,
            $customColor
        )
        let conversationFields = Publishers.CombineLatest3(
            $latestConversationMessage,
            $latestSubmittedMessage,
            $latestSubmittedAt
        )
        // Todo state is row-affecting (status pill, checklist progress) but
        // lives in its own sub-model, so fold its publishers in here the same
        // way the workspace's own @Published fields are.
        let todoFields = Publishers.CombineLatest3(
            todoState.$statusOverride,
            todoState.$statusHidden,
            todoState.$checklist
        )

        let immediateFields = workspaceFields
            .combineLatest(conversationFields, todoFields)
            .map { workspaceFields, conversationFields, todoFields in
                SidebarImmediateObservationState(
                    customTitle: workspaceFields.0,
                    customDescription: workspaceFields.1,
                    isPinned: workspaceFields.2,
                    customColor: workspaceFields.3,
                    latestConversationMessage: conversationFields.0,
                    latestSubmittedMessage: conversationFields.1,
                    latestSubmittedAt: conversationFields.2,
                    taskStatusOverride: todoFields.0,
                    statusHidden: todoFields.1,
                    checklist: todoFields.2
                )
            }
            .removeDuplicates()
            .coalesceLatest(
                for: Self.sidebarImmediateObservationCoalesceInterval,
                scheduler: DispatchQueue.main
            )
            .map { _ in () }

        return immediateFields.eraseToAnyPublisher()
    }

    /// Merged immediate observation across workspaces for the extension
    /// sidebar. Coalesced again across the merge: per-workspace coalescing
    /// caps each stream, but N workspaces bursting concurrently would still
    /// re-render the whole extension sidebar once per workspace per window.
    /// The leading edge stays synchronous, so a lone change is as immediate
    /// as before.
    static func mergedImmediateObservationPublisher(for workspaces: [Workspace]) -> AnyPublisher<Void, Never> {
        Publishers.MergeMany(workspaces.map { $0.sidebarImmediateObservationPublisher })
            .receive(on: DispatchQueue.main)
            .coalesceLatest(
                for: sidebarImmediateObservationCoalesceInterval,
                scheduler: DispatchQueue.main
            )
            .eraseToAnyPublisher()
    }

    func makeSidebarObservationPublisher() -> AnyPublisher<Void, Never> {
        let workspaceFields = Publishers.CombineLatest4(
            $currentDirectory,
            $extensionSidebarProjectRootPath,
            panelsPublisher.map(SidebarPanelObservationState.init),
            $panelDirectories
        )
        let metadataFields = Publishers.CombineLatest4(
            sidebarMetadata.statusEntriesPublisher,
            sidebarMetadata.metadataBlocksPublisher,
            sidebarMetadata.logEntriesPublisher,
            sidebarMetadata.progressPublisher
        )
        let gitFields = Publishers.CombineLatest4(
            sidebarMetadata.gitBranchPublisher,
            sidebarMetadata.panelGitBranchesPublisher,
            sidebarMetadata.pullRequestPublisher,
            sidebarMetadata.panelPullRequestsPublisher
        )
        let remoteFields = Publishers.CombineLatest4(
            $remoteConfiguration,
            $remoteConnectionState,
            $remoteConnectionDetail,
            $activeRemoteTerminalSessionCount
        )
        let directoryChangeRevision = currentDirectoryChangeRevisionPublisher()
        return Publishers.CombineLatest4(
            workspaceFields,
            metadataFields,
            gitFields,
            remoteFields
        )
            .combineLatest($listeningPorts, sidebarMetadata.panelDirectoryDisplayLabelsPublisher)
            .combineLatest(directoryChangeRevision)
            .compactMap { [weak self] values, directoryChangeRevision -> SidebarObservationState? in
                guard let self else { return nil }
                let (groupedFields, listeningPorts, panelDirectoryDisplayLabels) = values
                let workspaceFields = groupedFields.0
                let metadataFields = groupedFields.1
                let gitFields = groupedFields.2
                let remoteFields = groupedFields.3
                return SidebarObservationState(
                    currentDirectory: workspaceFields.0,
                    extensionSidebarProjectRootPath: workspaceFields.1,
                    panels: workspaceFields.2,
                    panelDirectories: workspaceFields.3,
                    panelDirectoryDisplayLabels: panelDirectoryDisplayLabels,
                    directoryChangeRevision: directoryChangeRevision,
                    statusEntries: metadataFields.0,
                    metadataBlocks: metadataFields.1,
                    logEntries: metadataFields.2,
                    progress: metadataFields.3,
                    gitBranch: gitFields.0,
                    panelGitBranches: gitFields.1,
                    pullRequest: gitFields.2,
                    panelPullRequests: gitFields.3,
                    remoteConfiguration: remoteFields.0,
                    remoteConnectionState: remoteFields.1,
                    remoteConnectionDetail: remoteFields.2,
                    activeRemoteTerminalSessionCount: remoteFields.3,
                    listeningPorts: listeningPorts,
                    browserMediaActivity: self.browserMediaActivity
                )
            }
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
