#if DEBUG
import SwiftUI
import CmuxSidebar

/// SwiftUI environment carrier for the debug-only per-window sidebar drag-state
/// registry the app owns at its composition root (`AppDelegate`).
///
/// The `debug.sidebar.simulate_drag` control command reads the live
/// ``SidebarDragState`` of a mounted sidebar by `windowId`. The sidebar view
/// registers/unregisters its `@State` ``SidebarDragState`` into this registry on
/// appear/disappear. Mirroring ``sidebarWorkspaceDragRegistry``, the composition
/// root injects its owned ``SidebarDragStateRegistry`` via
/// `.environment(\.sidebarDragStateRegistry, …)` so the sidebar wires to the
/// shared registry by injection instead of reaching `AppDelegate.shared`.
///
/// The default is `nil`, matching the legacy fallback: `AppDelegate.shared?` was
/// optional, so a reader with no injected registry simply does nothing
/// (`sidebarDragStateRegistry?.register(...)`), exactly as `AppDelegate.shared?`
/// short-circuited when the delegate was unavailable.
private struct SidebarDragStateRegistryKey: EnvironmentKey {
    static let defaultValue: SidebarDragStateRegistry? = nil
}

extension EnvironmentValues {
    /// The shared debug-only per-window sidebar drag-state registry injected from
    /// the app composition root, or `nil` when none has been injected.
    var sidebarDragStateRegistry: SidebarDragStateRegistry? {
        get { self[SidebarDragStateRegistryKey.self] }
        set { self[SidebarDragStateRegistryKey.self] = newValue }
    }
}
#endif
