public import Foundation
public import Bonsplit

/// The live-workspace read seam a concrete ``Panel`` reaches back into instead
/// of holding a `weak var workspace: Workspace` reference to the app-target
/// `Workspace` god object.
///
/// A panel that lives in this package cannot import the app target, so it cannot
/// name `Workspace`. The slice that moves concrete panels off the god replaces
/// each panel's `weak var workspace: Workspace` with a `weak var host: (any
/// WorkspacePanelHosting)?`, and the app target's `Workspace` conforms (the
/// app-side witness). Every member is a *read* the panel needs of its hosting
/// workspace; the workspace owns the state, the panel only observes it through
/// this seam.
///
/// The surface mirrors the live state the legacy panels reached through their
/// `workspace` back-reference:
///
/// - identity (``workspaceHostId``),
/// - the title/description vocabulary shown in chrome
///   (``workspaceHostTitle``, ``workspaceHostCustomTitle``,
///   ``workspaceHostCurrentDirectory``),
/// - focus and panel-registry lookups
///   (``workspaceHostFocusedPanelId``, ``workspaceHostPanel(forPanelId:)``,
///   ``workspaceHostPaneId(forPanelId:)``),
/// - the panel-lifecycle event hooks a panel fires when its surface opens or
///   closes (``workspaceHostPublishSurfaceCreated(...)``,
///   ``workspaceHostPublishSurfaceClosed(...)``). The concrete publish bodies
///   stay app-side (they touch `CmuxEventBus`/`TabManager`/Bonsplit pane state),
///   so the hooks are forwarded through the witness rather than reimplemented
///   here.
///
/// Isolation: `@MainActor`. Every member reads observable UI state or AppKit
/// responder/window-derived focus on the workspace, so the seam lives on the
/// main actor like ``Panel`` and its app-target conformer.
///
/// This is a read seam, not a no-op bridge: it exists so the panes package can
/// express the workspace coupling its concrete panels need without depending on
/// the app target, and so future panel moves (terminal, browser, agent session)
/// have a single typed contract to break their `Workspace` coupling against. A
/// panel that genuinely needs none of this surface (e.g. ``ProjectPanel``, which
/// takes only a project URL) simply does not hold a host.
@MainActor
public protocol WorkspacePanelHosting: AnyObject {
    /// The hosting workspace's stable identity (legacy `Workspace.id`). A panel
    /// stamps this onto events and snapshots it produces.
    var workspaceHostId: UUID { get }

    /// The workspace title shown in tab/chrome (legacy `Workspace.title`).
    var workspaceHostTitle: String { get }

    /// The user/auto custom title, or `nil` when none is set (legacy
    /// `Workspace.customTitle`).
    var workspaceHostCustomTitle: String? { get }

    /// The workspace's current working directory (legacy
    /// `Workspace.currentDirectory`).
    var workspaceHostCurrentDirectory: String { get }

    /// The currently focused pane's panel id, or `nil` (legacy
    /// `Workspace.focusedPanelId`).
    var workspaceHostFocusedPanelId: UUID? { get }

    /// Look up a sibling panel by its id (legacy `Workspace.panels[id]`).
    func workspaceHostPanel(forPanelId panelId: UUID) -> (any Panel)?

    /// Resolve the Bonsplit pane that hosts a panel id (legacy
    /// `Workspace.paneId(forPanelId:)`).
    func workspaceHostPaneId(forPanelId panelId: UUID) -> PaneID?

    /// Forward the surface-created lifecycle event the legacy panel fired
    /// through `workspace.publishCmuxSurfaceCreated(...)`. The witness owns the
    /// app-side publish body.
    func workspaceHostPublishSurfaceCreated(
        surfaceId: UUID,
        paneId: PaneID?,
        kind: String,
        origin: String,
        focused: Bool
    )

    /// Forward the surface-closed lifecycle event the legacy panel fired through
    /// `workspace.publishCmuxSurfaceClosed(...)`. The witness owns the app-side
    /// publish body.
    func workspaceHostPublishSurfaceClosed(
        surfaceId: UUID,
        paneId: PaneID?,
        panel: (any Panel)?,
        origin: String
    )
}
