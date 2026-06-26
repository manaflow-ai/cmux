import SwiftUI
import CmuxSidebar

/// SwiftUI environment carrier for the process-wide cross-window sidebar drag
/// registry the app owns at its composition root (`AppDelegate`).
///
/// `SidebarDragState` needs the shared ``SidebarWorkspaceDragRegistering`` at
/// construction so cross-window drops resolve a single in-flight drag. The
/// sidebar's `SidebarDragState` is `@State`, whose initializer cannot read the
/// environment, so the owning view reads this value and threads it into the
/// `SidebarDragState(workspaceDragRegistry:)` initializer. The composition root
/// injects its owned registry via `.environment(\.sidebarWorkspaceDragRegistry,
/// …)`; this inverts the former `AppDelegate.shared` global lookup that the
/// `SidebarDragState()` convenience initializer used.
///
/// The default is `nil`, matching the legacy fallback: a reader with no injected
/// registry builds a fresh one (`?? SidebarWorkspaceDragRegistry()`), exactly as
/// the old convenience initializer did when `AppDelegate.shared` was unavailable.
private struct SidebarWorkspaceDragRegistryKey: EnvironmentKey {
    static let defaultValue: (any SidebarWorkspaceDragRegistering)? = nil
}

extension EnvironmentValues {
    /// The shared cross-window sidebar drag registry injected from the app
    /// composition root, or `nil` when none has been injected.
    var sidebarWorkspaceDragRegistry: (any SidebarWorkspaceDragRegistering)? {
        get { self[SidebarWorkspaceDragRegistryKey.self] }
        set { self[SidebarWorkspaceDragRegistryKey.self] = newValue }
    }
}
