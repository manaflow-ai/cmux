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

private struct SidebarWorkspaceObservationFields: Equatable {
    let currentDirectory: String
    let extensionSidebarProjectRootPath: String?
    let panelDirectories: [UUID: String]
    let remoteConfiguration: WorkspaceRemoteConfiguration?
    let remoteConnectionState: WorkspaceRemoteConnectionState
    let remoteConnectionDetail: String?
    let activeRemoteTerminalSessionCount: Int
    let listeningPorts: [Int]
    let browserMediaActivity: BrowserMediaActivity
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
        observedValuesPublisher { [weak self] in
            guard let self else {
                return SidebarImmediateObservationState(
                    title: "",
                    customDescription: nil,
                    isPinned: false,
                    customColor: nil,
                    latestConversationMessage: nil,
                    latestSubmittedMessage: nil,
                    latestSubmittedAt: nil
                )
            }
            return SidebarImmediateObservationState(
                title: self.title,
                customDescription: self.customDescription,
                isPinned: self.isPinned,
                customColor: self.customColor,
                latestConversationMessage: self.latestConversationMessage,
                latestSubmittedMessage: self.latestSubmittedMessage,
                latestSubmittedAt: self.latestSubmittedAt
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
        let workspaceFields = observedValuesPublisher { [weak self] in
            guard let self else {
                return SidebarWorkspaceObservationFields(
                    currentDirectory: "",
                    extensionSidebarProjectRootPath: nil,
                    panelDirectories: [:],
                    remoteConfiguration: nil,
                    remoteConnectionState: .disconnected,
                    remoteConnectionDetail: nil,
                    activeRemoteTerminalSessionCount: 0,
                    listeningPorts: [],
                    browserMediaActivity: BrowserMediaActivity()
                )
            }
            return SidebarWorkspaceObservationFields(
                currentDirectory: self.currentDirectory,
                extensionSidebarProjectRootPath: self.extensionSidebarProjectRootPath,
                panelDirectories: self.panelDirectories,
                remoteConfiguration: self.remoteConfiguration,
                remoteConnectionState: self.remoteConnectionState,
                remoteConnectionDetail: self.remoteConnectionDetail,
                activeRemoteTerminalSessionCount: self.activeRemoteTerminalSessionCount,
                listeningPorts: self.listeningPorts,
                browserMediaActivity: self.browserMediaActivity
            )
        }
        let panels = panelsPublisher.map(SidebarPanelObservationState.init)
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
        let directoryChangeRevision = currentDirectoryChangeRevisionPublisher()
        return Publishers.CombineLatest4(
            workspaceFields,
            panels,
            metadataFields,
            gitFields
        )
            .combineLatest(sidebarMetadata.panelDirectoryDisplayLabelsPublisher)
            .combineLatest(directoryChangeRevision)
            .compactMap { [weak self] values, directoryChangeRevision -> SidebarObservationState? in
                guard let self else { return nil }
                let (groupedFields, panelDirectoryDisplayLabels) = values
                let workspaceFields = groupedFields.0
                let panels = groupedFields.1
                let metadataFields = groupedFields.2
                let gitFields = groupedFields.3
                return SidebarObservationState(
                    currentDirectory: workspaceFields.currentDirectory,
                    extensionSidebarProjectRootPath: workspaceFields.extensionSidebarProjectRootPath,
                    panels: panels,
                    panelDirectories: workspaceFields.panelDirectories,
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
                    remoteConfiguration: workspaceFields.remoteConfiguration,
                    remoteConnectionState: workspaceFields.remoteConnectionState,
                    remoteConnectionDetail: workspaceFields.remoteConnectionDetail,
                    activeRemoteTerminalSessionCount: workspaceFields.activeRemoteTerminalSessionCount,
                    listeningPorts: workspaceFields.listeningPorts,
                    browserMediaActivity: workspaceFields.browserMediaActivity
                )
            }
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
