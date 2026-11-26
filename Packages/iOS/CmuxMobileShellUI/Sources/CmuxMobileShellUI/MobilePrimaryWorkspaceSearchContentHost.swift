#if os(iOS)
import SwiftUI

struct MobilePrimaryWorkspaceSearchContentHost<Content: View>: View {
    @Bindable var searchCoordinator: MobilePrimarySearchCoordinator
    let content: (String) -> Content

    init(
        searchCoordinator: MobilePrimarySearchCoordinator,
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        self.searchCoordinator = searchCoordinator
        self.content = content
    }

    var body: some View {
        content(searchCoordinator.searchDestinationText(for: .workspaces))
    }
}
#endif
