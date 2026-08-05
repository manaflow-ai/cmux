import SwiftUI

enum SidebarWorkspaceGroupingMetrics {
    /// Leading inset applied to workspace rows that visually nest under a group header.
    /// Aligns an unpinned child title with the header title after its
    /// disclosure chevron, matching Arc's compact folder hierarchy.
    static let memberIndent: CGFloat = 18
}
