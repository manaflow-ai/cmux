import Combine
import CmuxCore
import Foundation
import CmuxSidebar

private struct SidebarPanelObservationState: Equatable {
    let panelIds: [UUID]

    init(panels: [UUID: any Panel]) {
        panelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
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
}

extension Workspace {
    func makeSidebarImmediateObservationPublisher() -> AnyPublisher<Void, Never> {
        let workspaceFields = Publishers.CombineLatest4(
            titlePublisher,
            customDescriptionPublisher,
            isPinnedPublisher,
            customColorPublisher
        )
        let conversationFields = Publishers.CombineLatest3(
            latestConversationMessagePublisher,
            latestSubmittedMessagePublisher,
            latestSubmittedAtPublisher
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
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    func makeSidebarObservationPublisher() -> AnyPublisher<Void, Never> {
        let workspaceFields = Publishers.CombineLatest4(
            currentDirectoryPublisher,
            extensionSidebarProjectRootPathPublisher,
            panelsPublisher.map(SidebarPanelObservationState.init),
            panelDirectoriesPublisher
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
            remoteConfigurationPublisher,
            remoteConnectionStatePublisher,
            remoteConnectionDetailPublisher,
            activeRemoteTerminalSessionCountPublisher
        )

        return Publishers.CombineLatest4(
            workspaceFields,
            metadataFields,
            gitFields,
            remoteFields
        )
            .combineLatest(listeningPortsPublisher)
            .map { groupedFields, listeningPorts in
                let workspaceFields = groupedFields.0
                let metadataFields = groupedFields.1
                let gitFields = groupedFields.2
                let remoteFields = groupedFields.3
                return SidebarObservationState(
                    currentDirectory: workspaceFields.0,
                    extensionSidebarProjectRootPath: workspaceFields.1,
                    panels: workspaceFields.2,
                    panelDirectories: workspaceFields.3,
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
                    listeningPorts: listeningPorts
                )
            }
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
