import Combine
import CmuxCore
import CmuxWorkspaces
import Foundation
import CmuxSidebar
import Observation
import SwiftUI

private struct SidebarPanelObservationState: Equatable {
    let panelIds: [UUID]

    init(panels: [UUID: any Panel]) {
        panelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
    }
}

extension View {
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
}

/// Settles automatic process-title churn before it invalidates a sidebar row.
/// Publication waits for `settleInterval` of quiet, but is never deferred more
/// than `maxDeferralInterval` past the first unpublished change: an agent TUI
/// that animates its title faster than the settle interval must still surface
/// a fresh title periodically instead of freezing the row until it goes quiet.
/// The injected scheduler keeps both deadlines deterministic in tests, while
/// the async stream ties row observation to SwiftUI task cancellation.
@MainActor
@Observable
final class WorkspaceSidebarProcessTitleObservationModel {
    typealias Cancellation = @MainActor () -> Void
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Cancellation

    nonisolated static let defaultSettleInterval: TimeInterval = 0.5
    nonisolated static let extensionSidebarAggregateInterval: TimeInterval = 0.05
    /// Staleness bound as a multiple of the settle interval: 2 s for sidebar
    /// rows, 0.2 s for the extension-sidebar aggregate.
    nonisolated static let maxDeferralFactor: Double = 4

    @ObservationIgnored
    private(set) var changeGeneration: UInt64 = 0
    @ObservationIgnored
    private var changeObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    @ObservationIgnored
    private var cancelSettleAction: Cancellation?
    @ObservationIgnored
    private var cancelDeferralDeadline: Cancellation?
    @ObservationIgnored
    private let settleInterval: TimeInterval
    @ObservationIgnored
    private let maxDeferralInterval: TimeInterval
    @ObservationIgnored
    private let schedule: Scheduler

    init(
        settleInterval: TimeInterval = defaultSettleInterval,
        maxDeferralInterval: TimeInterval? = nil,
        schedule: @escaping Scheduler = { delay, action in
            // Clamped far below Int.max nanoseconds (~292 years) so the Int
            // conversion cannot trap.
            let nanoseconds = min(max(0, delay) * 1_000_000_000.0, 9e18).rounded(.up)
            let timer = DispatchSource.makeTimerSource(queue: .main)
            // Generous leeway lets deadlines of concurrently churning
            // workspaces land in one main-queue drain, so SwiftUI folds their
            // row refreshes into a single layout transaction.
            timer.schedule(deadline: .now() + .nanoseconds(Int(nanoseconds)), leeway: .milliseconds(100))
            timer.setEventHandler {
                MainActor.assumeIsolated {
                    action()
                }
            }
            timer.resume()
            return {
                timer.setEventHandler {}
                timer.cancel()
            }
        }
    ) {
        self.settleInterval = max(0, settleInterval)
        self.maxDeferralInterval = max(0, maxDeferralInterval ?? settleInterval * Self.maxDeferralFactor)
        self.schedule = schedule
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            changeObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.changeObservers[id] = nil
                    if self.changeObservers.isEmpty {
                        self.cancelPendingProcessTitleChange()
                    }
                }
            }
        }
    }

    func processTitleDidChange() {
        guard !changeObservers.isEmpty else {
            cancelPendingProcessTitleChange()
            return
        }
        cancelSettleAction?()
        cancelSettleAction = schedule(settleInterval) { [weak self] in
            self?.publishSettledChange()
        }
        // Non-resetting staleness bound: changes spaced closer than the
        // settle interval reset the settle timer indefinitely, so without
        // this deadline a title animating at 10 Hz would never publish.
        if cancelDeferralDeadline == nil {
            cancelDeferralDeadline = schedule(maxDeferralInterval) { [weak self] in
                self?.publishSettledChange()
            }
        }
    }

    private func publishSettledChange() {
        cancelPendingProcessTitleChange()
        changeGeneration &+= 1
        for continuation in changeObservers.values {
            continuation.yield(())
        }
    }

    func cancelPendingProcessTitleChange() {
        cancelSettleAction?()
        cancelSettleAction = nil
        cancelDeferralDeadline?()
        cancelDeferralDeadline = nil
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
    static let sidebarImmediateObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(50)
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
                scheduler: RunLoop.main
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
            .receive(on: RunLoop.main)
            .coalesceLatest(
                for: sidebarImmediateObservationCoalesceInterval,
                scheduler: RunLoop.main
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
