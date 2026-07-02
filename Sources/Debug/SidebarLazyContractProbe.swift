import SwiftUI

#if DEBUG
/// Test-only body-evaluation probe for the workspace sidebar's lazy-layout
/// contract: sidebar layout/diff work must stay O(visible rows), never
/// O(all workspaces). The contract has regressed five times through five
/// different mechanisms (#2586, #5764, #5845, #6210, #6556), each shipping to
/// stable before being detected at scale. `SidebarLazyLayoutScaleTests` mounts
/// the sidebar with hundreds of workspaces, injects these closures, and fails
/// if row bodies are realized without bound or keep re-evaluating after
/// updates settle — regardless of which mechanism defeats laziness next.
///
/// Same pattern as `MinimalModeInvalidationProbe`; compiled out of Release.
struct SidebarLazyContractProbe {
    var workspaceRowBody: (() -> Void)?
    var groupHeaderRowBody: (() -> Void)?
}

struct SidebarLazyContractProbeKey: EnvironmentKey {
    static let defaultValue = SidebarLazyContractProbe()
}

extension EnvironmentValues {
    var sidebarLazyContractProbe: SidebarLazyContractProbe {
        get { self[SidebarLazyContractProbeKey.self] }
        set { self[SidebarLazyContractProbeKey.self] = newValue }
    }
}
#endif
