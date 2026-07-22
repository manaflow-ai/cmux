import SwiftUI

#if DEBUG
/// Test-only probe for the workspace sidebar virtualization contract: AppKit
/// must materialize viewport-many cells and reconfigure only changed hosted
/// roots, never all workspaces. `SidebarLazyLayoutScaleTests` mounts hundreds
/// of workspaces and fails on realization or reconfiguration churn.
///
/// Same pattern as `MinimalModeInvalidationProbe`; compiled out of Release.
struct SidebarLazyContractProbe {
    var workspaceRowBody: (() -> Void)?
    var workspaceRowBodyEnd: (() -> Void)?
    var groupHeaderRowBody: (() -> Void)?
    var workspaceSnapshotBuild: (() -> Void)?
    var tableRootViewReconfigure: (() -> Void)?
    var workspaceRowInputProjection: (() -> Void)?
}
#endif
