public import Foundation

/// Namespace for the immutable value types that describe one sidebar workspace
/// row's fully-resolved presentation.
///
/// A ``SidebarWorkspaceSnapshotBuilder/Snapshot`` is the single `Equatable`
/// value a sidebar row renders from: it folds the workspace title, custom
/// description/color/pin state, remote-connection text, agent log/progress,
/// metadata pills, git branch + directory lines, pull-request badges, and
/// forwarded ports into one snapshot so the row body never reads live model
/// state. ``SidebarWorkspaceSnapshotBuilder/PresentationKey`` captures only the
/// layout-affecting flags, so a row can compare keys to decide whether a
/// re-layout is needed independently of content changes.
///
/// The carrier is intentionally a static-free aggregate of nested value types;
/// it holds no logic, only the row's snapshot vocabulary.
public enum SidebarWorkspaceSnapshotBuilder {
    /// The subset of a snapshot that affects row *layout* (not content), so a
    /// row can detect a layout-relevant change without diffing the whole
    /// snapshot.
    public struct PresentationKey: Equatable, Sendable {
        /// Whether the custom workspace description line is shown.
        public let showsWorkspaceDescription: Bool
        /// Whether the branch + directory uses the multi-line vertical layout.
        public let usesVerticalBranchLayout: Bool
        /// Whether the git branch is shown at all.
        public let showsGitBranch: Bool
        /// Whether the viewport-aware directory truncation path is used.
        public let usesViewportAwarePath: Bool
        /// Which auxiliary detail rows are visible.
        public let visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility

        /// Creates a presentation key from its layout-affecting flags.
        public init(
            showsWorkspaceDescription: Bool,
            usesVerticalBranchLayout: Bool,
            showsGitBranch: Bool,
            usesViewportAwarePath: Bool,
            visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility
        ) {
            self.showsWorkspaceDescription = showsWorkspaceDescription
            self.usesVerticalBranchLayout = usesVerticalBranchLayout
            self.showsGitBranch = showsGitBranch
            self.usesViewportAwarePath = usesViewportAwarePath
            self.visibleAuxiliaryDetails = visibleAuxiliaryDetails
        }
    }

    /// One branch + directory line in the vertical branch layout.
    public struct VerticalBranchDirectoryLine: Equatable, Sendable {
        /// The branch name, or `nil` when no branch is shown on this line.
        public let branch: String?
        /// Ordered longest to shortest directory candidates. Empty means no
        /// directory to show; the first element is the canonical display string
        /// when only one is needed.
        public let directoryCandidates: [String]

        /// The canonical directory display string (the first candidate).
        public var directory: String? { directoryCandidates.first }

        /// Creates a vertical branch/directory line.
        public init(branch: String?, directoryCandidates: [String]) {
            self.branch = branch
            self.directoryCandidates = directoryCandidates
        }
    }

    /// The app-resolved, per-render tab content the builder folds into a
    /// ``SidebarWorkspaceSnapshotBuilder/Snapshot`` alongside the gathered
    /// branch/directory/pull-request value arrays.
    ///
    /// Every field here is read from live `Workspace`/`Tab` state by the
    /// app-side witness (titles, remote-connection strings, agent metadata,
    /// ports, the raw custom description) and passed through by value, so the
    /// builder performs only pure derivation and never touches model state. The
    /// auxiliary-detail arrays (`metadataEntries`/`metadataBlocks`/`latestLog`/
    /// `progress`/`listeningPorts`) arrive already gated by the witness on the
    /// row's auxiliary-detail visibility.
    public struct RowInputs: Equatable, Sendable {
        /// The displayed workspace title.
        public let title: String
        /// The raw custom workspace description (pre-visibility check), or `nil`.
        public let customDescription: String?
        /// Whether the workspace is pinned.
        public let isPinned: Bool
        /// The custom color hex, or `nil`.
        public let customColorHex: String?
        /// Remote workspace sidebar text, or `nil` for a local workspace.
        public let remoteWorkspaceSidebarText: String?
        /// The remote connection status text.
        public let remoteConnectionStatusText: String
        /// The remote state help text.
        public let remoteStateHelpText: String
        /// Whether to show the remote reconnect affordance.
        public let showsRemoteReconnectAffordance: Bool
        /// A copyable SSH error string, or `nil`.
        public let copyableSidebarSSHError: String?
        /// The latest conversation message, or `nil`.
        public let latestConversationMessage: String?
        /// The custom metadata pill entries (already gated).
        public let metadataEntries: [SidebarStatusEntry]
        /// The custom metadata blocks (already gated).
        public let metadataBlocks: [SidebarMetadataBlock]
        /// The latest log entry (already gated), or `nil`.
        public let latestLog: SidebarLogEntry?
        /// The agent progress state (already gated), or `nil`.
        public let progress: SidebarProgressState?
        /// The forwarded listening ports (already gated).
        public let listeningPorts: [Int]
        /// Browser media activity summarized for row affordances.
        public let mediaActivity: MediaActivity

        /// Creates the per-render tab content bundle.
        public init(
            title: String,
            customDescription: String?,
            isPinned: Bool,
            customColorHex: String?,
            remoteWorkspaceSidebarText: String?,
            remoteConnectionStatusText: String,
            remoteStateHelpText: String,
            showsRemoteReconnectAffordance: Bool,
            copyableSidebarSSHError: String?,
            latestConversationMessage: String?,
            metadataEntries: [SidebarStatusEntry],
            metadataBlocks: [SidebarMetadataBlock],
            latestLog: SidebarLogEntry?,
            progress: SidebarProgressState?,
            listeningPorts: [Int],
            mediaActivity: MediaActivity = MediaActivity()
        ) {
            self.title = title
            self.customDescription = customDescription
            self.isPinned = isPinned
            self.customColorHex = customColorHex
            self.remoteWorkspaceSidebarText = remoteWorkspaceSidebarText
            self.remoteConnectionStatusText = remoteConnectionStatusText
            self.remoteStateHelpText = remoteStateHelpText
            self.showsRemoteReconnectAffordance = showsRemoteReconnectAffordance
            self.copyableSidebarSSHError = copyableSidebarSSHError
            self.latestConversationMessage = latestConversationMessage
            self.metadataEntries = metadataEntries
            self.metadataBlocks = metadataBlocks
            self.latestLog = latestLog
            self.progress = progress
            self.listeningPorts = listeningPorts
            self.mediaActivity = mediaActivity
        }
    }

    /// One pull-request badge shown under a workspace row.
    public struct PullRequestDisplay: Identifiable, Equatable, Sendable {
        /// Stable identity for the badge (the PR's display key).
        public let id: String
        /// The pull-request number.
        public let number: Int
        /// The badge label.
        public let label: String
        /// The pull-request URL.
        public let url: URL
        /// The pull-request status driving the icon.
        public let status: SidebarPullRequestStatus
        /// Whether the badge is shown in a stale (dimmed) style.
        public let isStale: Bool

        /// Creates a pull-request badge value.
        public init(
            id: String,
            number: Int,
            label: String,
            url: URL,
            status: SidebarPullRequestStatus,
            isStale: Bool
        ) {
            self.id = id
            self.number = number
            self.label = label
            self.url = url
            self.status = status
            self.isStale = isStale
        }
    }

    /// Browser media activity summarized for the sidebar row.
    public struct MediaActivity: Equatable, Sendable {
        /// Whether any browser panel in the workspace is playing audio.
        public let isPlayingAudio: Bool
        /// Whether any browser panel in the workspace is using the microphone.
        public let isUsingMicrophone: Bool
        /// Whether any browser panel in the workspace is using the camera.
        public let isUsingCamera: Bool

        /// Creates a sidebar media-activity summary.
        public init(
            isPlayingAudio: Bool = false,
            isUsingMicrophone: Bool = false,
            isUsingCamera: Bool = false
        ) {
            self.isPlayingAudio = isPlayingAudio
            self.isUsingMicrophone = isUsingMicrophone
            self.isUsingCamera = isUsingCamera
        }
    }

    /// The fully-resolved presentation of one sidebar workspace row.
    public struct Snapshot: Equatable, Sendable {
        /// The layout-affecting subset, compared to detect re-layout needs.
        public let presentationKey: PresentationKey
        /// The displayed workspace title.
        public let title: String
        /// The custom workspace description, or `nil`.
        public let customDescription: String?
        /// Whether the workspace is pinned.
        public let isPinned: Bool
        /// The custom color hex, or `nil`.
        public let customColorHex: String?
        /// Remote workspace sidebar text, or `nil` for a local workspace.
        public let remoteWorkspaceSidebarText: String?
        /// The remote connection status text.
        public let remoteConnectionStatusText: String
        /// The remote state help text.
        public let remoteStateHelpText: String
        /// Whether to show the remote reconnect affordance.
        public let showsRemoteReconnectAffordance: Bool
        /// A copyable SSH error string, or `nil`.
        public let copyableSidebarSSHError: String?
        /// The latest conversation message, or `nil`.
        public let latestConversationMessage: String?
        /// The custom metadata pill entries.
        public let metadataEntries: [SidebarStatusEntry]
        /// The custom metadata blocks.
        public let metadataBlocks: [SidebarMetadataBlock]
        /// The latest log entry, or `nil`.
        public let latestLog: SidebarLogEntry?
        /// The agent progress state, or `nil`.
        public let progress: SidebarProgressState?
        /// The compact git branch summary text, or `nil`.
        public let compactGitBranchSummaryText: String?
        /// Compact directory candidates (longest to shortest).
        public let compactDirectoryCandidates: [String]
        /// Compact branch + directory candidates (longest to shortest).
        public let compactBranchDirectoryCandidates: [String]
        /// The vertical branch + directory lines.
        public let branchDirectoryLines: [VerticalBranchDirectoryLine]
        /// Whether the branch lines contain a branch name.
        public let branchLinesContainBranch: Bool
        /// The pull-request badges.
        public let pullRequestRows: [PullRequestDisplay]
        /// The forwarded listening ports.
        public let listeningPorts: [Int]
        /// The Finder directory path, or `nil`.
        public let finderDirectoryPath: String?
        /// Browser media activity summarized for row affordances.
        public let mediaActivity: MediaActivity

        /// Creates a fully-resolved sidebar row snapshot.
        public init(
            presentationKey: PresentationKey,
            title: String,
            customDescription: String?,
            isPinned: Bool,
            customColorHex: String?,
            remoteWorkspaceSidebarText: String?,
            remoteConnectionStatusText: String,
            remoteStateHelpText: String,
            showsRemoteReconnectAffordance: Bool,
            copyableSidebarSSHError: String?,
            latestConversationMessage: String?,
            metadataEntries: [SidebarStatusEntry],
            metadataBlocks: [SidebarMetadataBlock],
            latestLog: SidebarLogEntry?,
            progress: SidebarProgressState?,
            compactGitBranchSummaryText: String?,
            compactDirectoryCandidates: [String],
            compactBranchDirectoryCandidates: [String],
            branchDirectoryLines: [VerticalBranchDirectoryLine],
            branchLinesContainBranch: Bool,
            pullRequestRows: [PullRequestDisplay],
            listeningPorts: [Int],
            finderDirectoryPath: String?,
            mediaActivity: MediaActivity = MediaActivity()
        ) {
            self.presentationKey = presentationKey
            self.title = title
            self.customDescription = customDescription
            self.isPinned = isPinned
            self.customColorHex = customColorHex
            self.remoteWorkspaceSidebarText = remoteWorkspaceSidebarText
            self.remoteConnectionStatusText = remoteConnectionStatusText
            self.remoteStateHelpText = remoteStateHelpText
            self.showsRemoteReconnectAffordance = showsRemoteReconnectAffordance
            self.copyableSidebarSSHError = copyableSidebarSSHError
            self.latestConversationMessage = latestConversationMessage
            self.metadataEntries = metadataEntries
            self.metadataBlocks = metadataBlocks
            self.latestLog = latestLog
            self.progress = progress
            self.compactGitBranchSummaryText = compactGitBranchSummaryText
            self.compactDirectoryCandidates = compactDirectoryCandidates
            self.compactBranchDirectoryCandidates = compactBranchDirectoryCandidates
            self.branchDirectoryLines = branchDirectoryLines
            self.branchLinesContainBranch = branchLinesContainBranch
            self.pullRequestRows = pullRequestRows
            self.listeningPorts = listeningPorts
            self.finderDirectoryPath = finderDirectoryPath
            self.mediaActivity = mediaActivity
        }
    }
}
