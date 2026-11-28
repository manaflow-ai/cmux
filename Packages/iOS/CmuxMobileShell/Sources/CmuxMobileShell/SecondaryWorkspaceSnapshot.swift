import CmuxMobileShellModel

/// One successfully decoded secondary Mac workspace snapshot.
///
/// A `nil` group list means the response did not contain authoritative group
/// metadata, so the caller preserves that Mac's prior group snapshot. An empty
/// list is authoritative and clears its prior groups.
struct SecondaryWorkspaceSnapshot: Equatable, Sendable {
    let workspaces: [MobileWorkspacePreview]
    let groups: [MobileWorkspaceGroupPreview]?
}
