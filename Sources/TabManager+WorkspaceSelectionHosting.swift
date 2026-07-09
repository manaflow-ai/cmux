import CmuxWorkspaces
import Foundation

/// `TabManager`'s conformance to the `CmuxWorkspaces` `WorkspaceSelectionHosting`
/// seam: the irreducible app-coupled effects behind the workspace selection
/// navigation that the package `WorkspaceSelectionCoordinator` cannot own.
///
/// The coordinator keeps the next/previous wrap-around order math, the
/// select-by-index and select-last guards, and the cycle-hot window state
/// machine (generation counter + cooldown task + the `BackgroundWorkspaceLoadModel`
/// `isWorkspaceCycleHot` flag). This conformance performs the actual selection
/// mutation (the legacy private `selectWorkspaceId(_:notificationDismissalContext:)`,
/// which sets `selectedTabId` and runs the full selection side-effect chain over
/// the app-target `Workspace` god object), the keyboard-nav sidebar
/// multi-selection collapse (through the `SidebarMultiSelectionModel`), and the
/// DEBUG workspace-switch tracing (`cmuxDebugLog` plus the app-target switch-id /
/// start-time bookkeeping).
///
/// The witnesses live in `TabManager`'s class body (not here) because they reach
/// the god object's `private` selection-mutation chain and `private` DEBUG
/// switch-trace state; this file only binds the conformance, mirroring the
/// sibling `FocusedSurfaceHosting` / `SurfaceMetadataTitleHosting` split.
extension TabManager: WorkspaceSelectionHosting {}
