import CmuxFoundation
import SwiftUI

/// Resolves the broad SwiftUI environment at a lightweight boundary before
/// the O(workspaces) sidebar projection. Unrelated environment changes can
/// re-evaluate this reader, but its compact snapshot and required Equatable
/// content boundary discard them before the sidebar projection runs.
@MainActor
struct SidebarWorkspaceTableEnvironmentReader<Content: View & Equatable>: View {
    @Environment(\.self) private var environment

    private let content: (SidebarWorkspaceTableEnvironmentSnapshot) -> Content

    init(
        @ViewBuilder content: @escaping (SidebarWorkspaceTableEnvironmentSnapshot) -> Content
    ) {
        self.content = content
    }

    var body: some View {
#if DEBUG
        content(SidebarWorkspaceTableEnvironmentSnapshot(
            environment: environment,
            globalFontMagnificationPercent: environment.cmuxGlobalFontMagnificationPercent,
            lazyContractProbe: environment.sidebarLazyContractProbe
        )).equatable()
#else
        content(SidebarWorkspaceTableEnvironmentSnapshot(
            environment: environment,
            globalFontMagnificationPercent: environment.cmuxGlobalFontMagnificationPercent
        )).equatable()
#endif
    }
}
