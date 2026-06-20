public import Foundation

/// Resolves the workspace handle that owns a terminal surface's tab.
///
/// Inverts the app-target reach-up that mapped a surface's `tabId` to its
/// owning workspace through the `AppDelegate.shared` singleton. The app target
/// conforms (binding `Workspace` to its concrete workspace model) and injects a
/// concrete resolver at the composition root, so `TerminalSurface.owningWorkspace()`
/// no longer reads a global.
///
/// `Workspace` is a primary associated type: the seam is owned low (here, with
/// the rest of the surface-registry inversions) and parameterized by the app's
/// concrete workspace type, which `CmuxTerminalCore` cannot name. Callers keep
/// receiving the concrete workspace, so the resolution stays byte-identical at
/// every call site.
@MainActor
public protocol WorkspaceResolving<Workspace>: AnyObject {
    /// The concrete workspace handle the app target resolves a tab to.
    associatedtype Workspace

    /// Returns the workspace that owns `tabId`, or `nil` when none is registered.
    ///
    /// - Parameter tabId: The owning-tab identifier carried by a terminal surface.
    func workspace(forTabId tabId: UUID) -> Workspace?
}
