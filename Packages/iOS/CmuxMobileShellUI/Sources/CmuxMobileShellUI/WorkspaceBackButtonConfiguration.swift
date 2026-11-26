import SwiftUI

struct WorkspaceBackButtonConfiguration {
    let unreadCount: Int
    let badgeContrast: WorkspaceBackButtonBadgeContrast
    let action: () -> Void
}
