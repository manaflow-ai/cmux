import SwiftUI

/// Reports hosted-content size invalidation without mutating table geometry during rendering.
@MainActor
final class SidebarWorkspaceTableHostingView:
    NSHostingView<SidebarWorkspaceTableCellRootView> {
    var contentSizeDidInvalidate: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        contentSizeDidInvalidate?()
    }
}
