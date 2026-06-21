public import SwiftUI
public import CmuxSidebar

extension SidebarLogLevel {
    /// The sidebar log-line color used when the workspace row is NOT active.
    ///
    /// Lifted byte-identically from the inactive branch of the app target's
    /// `TabItemView.logLevelColor(_:isActive:)`. The active-row branch derives
    /// from the row's inverted selection foreground (an app-target appearance
    /// helper), so it stays at the call site; only this row-independent mapping
    /// moves onto the owning type, where it needs SwiftUI's `Color`.
    public var inactiveSidebarColor: Color {
        switch self {
        case .info: return .secondary
        case .progress: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
