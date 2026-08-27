import SwiftUI

#if DEBUG
struct MinimalModeInvalidationProbe {
    var contentViewBody: (() -> Void)?
    var workspaceContentBody: (() -> Void)?
    var verticalTabsSidebarBody: (() -> Void)?
}
#endif
