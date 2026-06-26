import CmuxWorkspaces
import Foundation

/// `TabManager`'s conformance to the `CmuxWorkspaces` `WorkspaceCreationHosting`
/// seam: the irreducible app-coupled effects behind new-workspace creation that
/// the package `WorkspaceCreationCoordinator` cannot own.
///
/// The coordinator keeps the pre-creation `WorkspaceCreationSnapshot` capture,
/// the placement-driven insertion index, the live-array `tabs` insertion, the
/// group-contiguity normalization, the selection-after-create assignment, and
/// the `withExtendedLifetime` ARC guard + interleave order. This conformance
/// performs each concrete creation effect against the app-target `Workspace`
/// god object / `AppDelegate`: the source-workspace inheritance reads, the
/// `Workspace` construction + chrome inheritance + back-pointer + closed-browser
/// wiring, the process-wide port-ordinal allocation, the Sentry breadcrumb, the
/// background-load request, the initial sidebar git-metadata schedule, the
/// eager-load surface prime, the two `cmux.workspace.created` / initial-surface
/// lifecycle publishes, the `ghosttyDidFocusTab` notification, the welcome
/// command send, and the `#if DEBUG` switch-trigger prime + `UITestRecorder`
/// telemetry + dev selection-mutation hook.
///
/// The witnesses live in `TabManager`'s class body (not here) because they reach
/// the god object's shared inheritance helpers (`makeWorkspaceForCreation`,
/// `applyCreationChromeInheritance`, `workspaceCreationConfigTemplate`,
/// `inheritedTerminalFontPointsForNewWorkspace`,
/// `implicitWorkingDirectoryForNewWorkspace`) — which `TabManager+DetachedWorkspace`
/// and the test subclasses also call — and the `private`
/// `sendWelcomeWhenReady(to:)` fallback; this file only binds the conformance,
/// mirroring the sibling `WorkspaceCloseHosting` / `WorkspaceSelectionHosting`
/// split.
extension TabManager: WorkspaceCreationHosting {}
