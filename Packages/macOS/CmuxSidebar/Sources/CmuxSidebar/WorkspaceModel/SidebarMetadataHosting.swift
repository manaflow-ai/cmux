public import Foundation

/// Read-only seam the sidebar directory/order projection reads to resolve each
/// panel's working directory and the workspace-level canonicalization inputs
/// without importing the app-target `Workspace`/`Panel` types.
///
/// The app target's `Workspace` conforms to this protocol. ``SidebarDirectoryResolver``
/// (the package-side projection logic) is constructed with a host conforming to
/// this seam and reads only these accessors, so the directory-resolution and
/// canonicalization-home derivations the legacy `Workspace` DirectoryUpdates
/// section performed inline now live in the owning sidebar domain while the
/// irreducible live-state reads (bonsplit spatial order, `TerminalPanel`
/// requested directory, remote-surface classification, the focused panel) stay
/// behind this read-only contract.
///
/// `PanelIdentifiable`-style by design: every member keys on a `UUID` panel id
/// and returns plain value types, so the package never sees a `Panel`.
@MainActor
public protocol SidebarMetadataHosting: AnyObject {
    /// The workspace's currently focused panel id, or `nil` when none is
    /// focused (legacy `Workspace.focusedPanelId`).
    var sidebarFocusedPanelId: UUID? { get }

    /// The workspace's current directory used as the directory-resolution and
    /// canonicalization fallback (legacy `Workspace.currentDirectory`).
    var sidebarCurrentDirectory: String { get }

    /// Whether this workspace is a Cloud VM / remote workspace, which selects
    /// the inferred-remote-home canonicalization path (legacy
    /// `Workspace.isRemoteWorkspace`).
    var sidebarIsRemoteWorkspace: Bool { get }

    /// The panel's last-reported working directory, if known (legacy
    /// `Workspace.panelDirectories[panelId]`).
    /// - Parameter panelId: The panel whose reported directory is read.
    /// - Returns: The raw directory string, or `nil` if none is recorded.
    func sidebarPanelDirectory(for panelId: UUID) -> String?

    /// The panel's requested working directory from its terminal configuration,
    /// if the panel is a terminal panel with one (legacy
    /// `Workspace.terminalPanel(for: panelId)?.requestedWorkingDirectory`).
    /// - Parameter panelId: The panel whose requested directory is read.
    /// - Returns: The raw requested directory string, or `nil`.
    func sidebarPanelRequestedWorkingDirectory(for panelId: UUID) -> String?

    /// The panel ids in on-screen spatial (bonsplit) order, which
    /// ``SidebarDisplayOrderProjection`` projects the display-order rows over
    /// (legacy `Workspace.sidebarOrderedPanelIds()`).
    ///
    /// The bonsplit split-tree walk that produces this order reads app-target
    /// pane/tab state the package cannot import, so it is the irreducible
    /// live-state read kept in the `Workspace` shim behind this seam.
    var sidebarSpatialPanelOrder: [UUID] { get }

    /// Whether a panel is a remote-display surface (Cloud VM detected, remote
    /// terminal, or pending remote-terminal child exit), used by
    /// ``SidebarDisplayOrderProjection/finderDirectory()`` to keep only local
    /// panels when picking the Finder-reveal directory (legacy
    /// `Workspace.sidebarFinderDirectory()` local-panel filter).
    /// - Parameter panelId: The panel whose remote classification is read.
    /// - Returns: `true` when the panel is a remote-display surface.
    func sidebarIsRemoteDisplaySurface(_ panelId: UUID) -> Bool

    /// The structured-hook status entries currently visible for display, already
    /// filtered by the live agent-visibility rules (legacy
    /// `Workspace.sidebarStatusEntriesVisibleForDisplay()`).
    ///
    /// The agent-PID / panel visibility filtering reads live `Workspace` state
    /// the package cannot import, so it stays in the shim and hands the
    /// already-filtered entries to ``SidebarDisplayOrderProjection`` for the
    /// pure ordering step.
    var sidebarVisibleStatusEntriesForDisplay: [SidebarStatusEntry] { get }
}
