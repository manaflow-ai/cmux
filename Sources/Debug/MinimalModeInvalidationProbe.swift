import SwiftUI

#if DEBUG
struct MinimalModeInvalidationProbe {
    /// Armed only during a test's measured transition; never observes app state.
    var shouldTraceBodyChanges: (() -> Bool)?
    var contentViewBody: (() -> Void)?
    var workspaceContentBody: (() -> Void)?
    var verticalTabsSidebarBody: (() -> Void)?
}
#endif
