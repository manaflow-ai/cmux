import CmuxSettings
import SwiftUI

enum SidebarWorkspaceGroupingMetrics {
    /// Default leading inset applied to workspace rows that visually nest under a
    /// group header. Rows read the configured `sidebar.groupMemberIndent` from
    /// ``SidebarTabItemSettingsSnapshot/groupMemberIndent``.
    static let memberIndent = CGFloat(SidebarCatalogSection().groupMemberIndent.defaultValue)
}
