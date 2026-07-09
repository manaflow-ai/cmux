internal import Foundation

/// Resolved visibility of the auxiliary detail rows under a sidebar
/// workspace row (metadata pills, log line, progress, branch/directory,
/// pull requests, ports).
///
/// The master "hide all details" switch wins over every individual toggle;
/// ``resolved(showMetadata:showLog:showProgress:showBranchDirectory:showPullRequests:showPorts:hideAllDetails:)``
/// applies exactly that legacy precedence.
public struct SidebarWorkspaceAuxiliaryDetailVisibility: Equatable, Sendable {
    /// Whether custom metadata pills are shown.
    public let showsMetadata: Bool
    /// Whether the latest log line is shown.
    public let showsLog: Bool
    /// Whether agent progress is shown.
    public let showsProgress: Bool
    /// Whether the branch/directory line is shown.
    public let showsBranchDirectory: Bool
    /// Whether pull-request badges are shown.
    public let showsPullRequests: Bool
    /// Whether forwarded-port rows are shown.
    public let showsPorts: Bool

    /// Creates a visibility value with each row's flag as given.
    public init(
        showsMetadata: Bool,
        showsLog: Bool,
        showsProgress: Bool,
        showsBranchDirectory: Bool,
        showsPullRequests: Bool,
        showsPorts: Bool
    ) {
        self.showsMetadata = showsMetadata
        self.showsLog = showsLog
        self.showsProgress = showsProgress
        self.showsBranchDirectory = showsBranchDirectory
        self.showsPullRequests = showsPullRequests
        self.showsPorts = showsPorts
    }

    /// Every row hidden.
    public static let hidden = Self(
        showsMetadata: false,
        showsLog: false,
        showsProgress: false,
        showsBranchDirectory: false,
        showsPullRequests: false,
        showsPorts: false
    )

    /// Combines the individual row toggles with the master "hide all
    /// details" switch: when `hideAllDetails` is set every row is hidden
    /// regardless of its own toggle.
    public static func resolved(
        showMetadata: Bool,
        showLog: Bool,
        showProgress: Bool,
        showBranchDirectory: Bool,
        showPullRequests: Bool,
        showPorts: Bool,
        hideAllDetails: Bool
    ) -> Self {
        guard !hideAllDetails else { return .hidden }
        return Self(
            showsMetadata: showMetadata,
            showsLog: showLog,
            showsProgress: showProgress,
            showsBranchDirectory: showBranchDirectory,
            showsPullRequests: showPullRequests,
            showsPorts: showPorts
        )
    }
}
