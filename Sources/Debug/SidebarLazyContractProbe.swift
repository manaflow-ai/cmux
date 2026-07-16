import SwiftUI

#if DEBUG
/// Test-only probe for the workspace sidebar virtualization contract: the
/// AppKit table must materialize viewport-many cells and reconfigure only
/// changed hosted roots, never all workspaces. The old SwiftUI lazy-layout
/// contract regressed five times through five different mechanisms (#2586,
/// #5764, #5845, #6210, #6556), each shipping to stable before being detected
/// at scale. `SidebarLazyLayoutScaleTests` mounts the sidebar with hundreds
/// of workspaces, injects these closures, and fails if row bodies are
/// realized without bound or keep re-evaluating after updates settle.
///
/// Same pattern as `MinimalModeInvalidationProbe`; compiled out of Release.
struct SidebarLazyContractProbe {
    var workspaceRowBody: (() -> Void)?
    var workspaceRowBodyEnd: (() -> Void)?
    var groupHeaderRowBody: (() -> Void)?
    var workspaceSnapshotBuild: (() -> Void)?
    var workspaceRowInputProjection: (() -> Void)?
    var tableRootViewReconfigure: (() -> Void)?
}
#endif
