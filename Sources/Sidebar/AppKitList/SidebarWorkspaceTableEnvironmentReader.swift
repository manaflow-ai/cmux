import CmuxFoundation
import SwiftUI

/// Resolves the broad SwiftUI environment at a lightweight boundary before
/// the O(workspaces) sidebar projection. Unrelated environment changes can
/// re-evaluate this reader, but the compact snapshot lets the inner
/// `VerticalTabsSidebar.equatable()` gate discard them.
@MainActor
struct SidebarWorkspaceTableEnvironmentReader<Content: View>: View {
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
        ))
#else
        content(SidebarWorkspaceTableEnvironmentSnapshot(
            environment: environment,
            globalFontMagnificationPercent: environment.cmuxGlobalFontMagnificationPercent
        ))
#endif
    }
}
