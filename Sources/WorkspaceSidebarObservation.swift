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

/// Aggregate "is any browser pane in this workspace using a media device"
/// summary, folded across every ``BrowserPanel`` in a ``Workspace``. Drives the
/// Chrome-style media-activity glyphs on the sidebar workspace row.
struct BrowserMediaActivity: Equatable {
    /// Any browser pane is producing audible audio (private `_isPlayingAudio`).
    var isPlayingAudio: Bool = false
    /// Any browser pane is capturing the microphone.
    var isUsingMicrophone: Bool = false
    /// Any browser pane is capturing the camera.
    var isUsingCamera: Bool = false

    /// Whether any tracked media device is active (used to gate row layout).
    var isActive: Bool { isPlayingAudio || isUsingMicrophone || isUsingCamera }

    /// Reduces per-pane media activity into the workspace-level summary: a
    /// device counts as active when *any* pane reports it active. Pure so the
    /// "any browser pane in the workspace is playing audio" rule is unit-testable
    /// without standing up a full ``Workspace``/``BrowserPanel`` graph.
    static func aggregating<S: Sequence>(_ perPane: S) -> BrowserMediaActivity
    where S.Element == BrowserMediaActivity {
        perPane.reduce(into: BrowserMediaActivity()) { result, pane in
            result.isPlayingAudio = result.isPlayingAudio || pane.isPlayingAudio
            result.isUsingMicrophone = result.isUsingMicrophone || pane.isUsingMicrophone
            result.isUsingCamera = result.isUsingCamera || pane.isUsingCamera
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
            .map { _ in () }
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

        return Publishers.CombineLatest4(
            workspaceFields,
            metadataFields,
            gitFields,
            remoteFields
        )
            .combineLatest($listeningPorts, $browserMediaActivity)
            .map { groupedFields, listeningPorts, browserMediaActivity in
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
                    listeningPorts: listeningPorts,
                    browserMediaActivity: browserMediaActivity
                )
            }
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
