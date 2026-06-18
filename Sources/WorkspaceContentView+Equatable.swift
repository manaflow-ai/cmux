import Foundation

/// `ContentView.terminalContent` mounts each workspace with `.equatable()` so
/// window-root body re-evaluations (titlebar text churn, selection changes,
/// and the minimal-mode toggle's titlebar band mount/unmount,
/// https://github.com/manaflow-ai/cmux/issues/5732) no longer re-evaluate the
/// mounted workspace's Bonsplit tree. Closures and observed stores are
/// excluded: `workspace` and `notificationStore` invalidate the view through
/// their own subscriptions, and `onThemeRefreshRequest` only routes to stable
/// owner state.
extension WorkspaceContentView: Equatable {
    nonisolated static func == (lhs: WorkspaceContentView, rhs: WorkspaceContentView) -> Bool {
        // EquatableView diffing runs on the main thread; hop in explicitly to
        // read the MainActor-isolated @ObservedObject storage. If SwiftUI ever
        // compares off-main, fall back to "not equal" — an extra render is
        // always safe, a stale skip is not.
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            lhs.workspace === rhs.workspace &&
            lhs.isWorkspaceVisible == rhs.isWorkspaceVisible &&
            lhs.isWorkspaceInputActive == rhs.isWorkspaceInputActive &&
            lhs.isFullScreen == rhs.isFullScreen &&
            lhs.workspacePortalPriority == rhs.workspacePortalPriority
        }
    }
}
