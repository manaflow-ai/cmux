import Combine
import CmuxCore
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
}

private struct SidebarImmediateObservationState: Equatable {
    let title: String
    let customDescription: String?
    let isPinned: Bool
    let customColor: String?
    let latestConversationMessage: String?
    let latestSubmittedMessage: String?
    let latestSubmittedAt: Date?
}

private struct SidebarObservationState: Equatable {
    let currentDirectory: String
    let extensionSidebarProjectRootPath: String?
    let panels: SidebarPanelObservationState
    let panelDirectories: [UUID: String]
    let panelDirectoryDisplayLabels: [UUID: String]
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
    let remoteDaemonStatus: WorkspaceRemoteDaemonStatus
    let activeRemoteTerminalSessionCount: Int
    let listeningPorts: [Int]
    let browserMediaActivity: BrowserMediaActivity
}

extension Workspace {
    // Leading-edge coalescing for the immediate sidebar observation stream.
    // Every subscription (a sidebar row, the MergeMany extension-sidebar
    // aggregate) fires a full makeWorkspaceSnapshot() rebuild per emission.
    // Agents (e.g. Codex) rewrite a workspace title every turn, and
    // removeDuplicates() cannot collapse distinct titles, so without coalescing
    // each rewrite drives a snapshot rebuild per consumer per workspace.
    // coalesceLatest (below) keeps the first change in a burst synchronous
    // (a user pin/color/title edit stays immediate, which Combine's throttle
    // cannot guarantee because it schedules every emission onto the scheduler)
    // and collapses the tail of the burst into one trailing emission per window.
    // See https://github.com/manaflow-ai/cmux/issues/4127.
    static let sidebarImmediateObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(50)

    func makeSidebarImmediateObservationPublisher() -> AnyPublisher<Void, Never> {
        let workspaceFields = Publishers.CombineLatest4(
            $title,
            $customDescription,
            $isPinned,
            $customColor
        )
        let conversationFields = Publishers.CombineLatest3(
            $latestConversationMessage,
            $latestSubmittedMessage,
            $latestSubmittedAt
        )

        return workspaceFields
            .combineLatest(conversationFields)
            .map { workspaceFields, conversationFields in
                SidebarImmediateObservationState(
                    title: workspaceFields.0,
                    customDescription: workspaceFields.1,
                    isPinned: workspaceFields.2,
                    customColor: workspaceFields.3,
                    latestConversationMessage: conversationFields.0,
                    latestSubmittedMessage: conversationFields.1,
                    latestSubmittedAt: conversationFields.2
                )
            }
            .removeDuplicates()
            .coalesceLatest(
                for: Self.sidebarImmediateObservationCoalesceInterval,
                scheduler: RunLoop.main
            )
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func makeSidebarRootObservationPublisher() -> AnyPublisher<Void, Never> {
        let remoteFields = Publishers.CombineLatest4(
            $remoteConfiguration,
            $remoteConnectionState,
            $remoteConnectionDetail,
            $remoteDaemonStatus
        )
        .combineLatest(
            $activeRemoteTerminalSessionCount
        )

        return $currentDirectory
            .combineLatest(remoteFields)
            .map { currentDirectory, remoteFields in
                SidebarRootObservationState(
                    currentDirectory: currentDirectory,
                    remoteConfiguration: remoteFields.0.0,
                    remoteConnectionState: remoteFields.0.1,
                    remoteConnectionDetail: remoteFields.0.2,
                    remoteDaemonStatus: remoteFields.0.3,
                    activeRemoteTerminalSessionCount: remoteFields.1
                )
            }
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
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
            $remoteDaemonStatus
        )
        .combineLatest(
            $activeRemoteTerminalSessionCount
        )
        return Publishers.CombineLatest4(
            workspaceFields,
            metadataFields,
            gitFields,
            remoteFields
        )
            .combineLatest($listeningPorts, sidebarMetadata.panelDirectoryDisplayLabelsPublisher)
            .compactMap { [weak self] groupedFields, listeningPorts, panelDirectoryDisplayLabels -> SidebarObservationState? in
                guard let self else { return nil }
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
                    statusEntries: metadataFields.0,
                    metadataBlocks: metadataFields.1,
                    logEntries: metadataFields.2,
                    progress: metadataFields.3,
                    gitBranch: gitFields.0,
                    panelGitBranches: gitFields.1,
                    pullRequest: gitFields.2,
                    panelPullRequests: gitFields.3,
                    remoteConfiguration: remoteFields.0.0,
                    remoteConnectionState: remoteFields.0.1,
                    remoteConnectionDetail: remoteFields.0.2,
                    remoteDaemonStatus: remoteFields.0.3,
                    activeRemoteTerminalSessionCount: remoteFields.1,
                    listeningPorts: listeningPorts,
                    browserMediaActivity: self.browserMediaActivity
                )
            }
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
