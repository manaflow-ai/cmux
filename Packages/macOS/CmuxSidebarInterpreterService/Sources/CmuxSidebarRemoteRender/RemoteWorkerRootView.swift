import CmuxSwiftRenderUI
import SwiftUI

/// The worker's SwiftUI root: the shared sidebar presentation plus collection
/// of the rendered tree's tap targets, so the coordinator can hit-test
/// forwarded clicks geometrically.
struct RemoteWorkerRootView: View {
    let content: CustomSidebarContentView
    /// Receives the rendered tree's tappable regions after each layout pass.
    let onTapTargetsChange: @MainActor @Sendable ([SidebarTapTarget]) -> Void

    var body: some View {
        content
            .onPreferenceChange(SidebarTapTargetsKey.self) { targets in
                Task { @MainActor in
                    onTapTargetsChange(targets)
                }
            }
    }
}
