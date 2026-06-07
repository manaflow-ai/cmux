internal import CmuxMobileShellModel

/// The result of an on-demand `workspace.list` refresh for one non-active
/// paired Mac, carried back from the fan-out task group to the partition writer.
///
/// Pairs the Mac's identity with either the freshly mapped workspaces or an
/// `.unavailable` marker, so the writer can update that Mac's list partition and
/// section status under the post-`await` re-guard on the main actor.
struct MacWorkspaceListRefreshOutcome: Sendable {
    /// Whether the transient `workspace.list` succeeded, and its payload.
    enum Result: Sendable {
        /// The Mac responded; its mapped, source-tagged workspaces.
        case workspaces([MobileWorkspacePreview])
        /// The Mac was unreachable or rejected the request; keep the last-known
        /// partition but gray the section.
        case unavailable
    }

    /// Stable identifier of the paired Mac this outcome belongs to.
    let macDeviceID: String
    /// Human-readable name of the paired Mac, for its section header.
    let displayName: String
    /// The fetch result for the Mac's list partition.
    let result: Result
}
