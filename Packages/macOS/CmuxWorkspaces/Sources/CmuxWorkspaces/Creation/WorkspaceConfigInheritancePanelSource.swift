public import Foundation

/// The flattened, `Sendable` snapshot of a workspace's terminal-panel state
/// that decides which panel a new workspace inherits its Ghostty config from.
///
/// The legacy `TabManager.terminalPanelForWorkspaceConfigInheritanceSource`
/// body read three things off the live source `Workspace`: the remembered
/// config-inheritance panel (`lastRememberedTerminalPanelForConfigInheritance`),
/// every terminal panel in `panels` sorted by `id.uuidString`, and, for each,
/// whether its surface is live (`surface.hasLiveSurface && surface.surface !=
/// nil`). Those are pure value reads, so the app-side witness flattens them
/// into this struct and the package-pure ``WorkspaceCreationInheritanceResolver``
/// performs the candidate ordering + first-live selection without touching the
/// app target's `TerminalPanel`/`TerminalSurface` types.
///
/// `orderedTerminalPanelIds` is already sorted by the witness in the legacy
/// `id.uuidString` order, and the remembered id (when present) is the
/// highest-priority candidate; the resolver dedups the remembered id against the
/// ordered list exactly as the legacy `seen`-set `appendCandidate` did.
public struct WorkspaceConfigInheritancePanelSource: Sendable {
    /// The remembered config-inheritance panel's id, or `nil` when none is
    /// remembered (legacy `lastRememberedTerminalPanelForConfigInheritance()?.id`).
    public var rememberedPanelId: UUID?

    /// Every terminal panel id in the workspace, in the legacy
    /// `panels.values.compactMap(TerminalPanel).sorted(by: id.uuidString)` order.
    public var orderedTerminalPanelIds: [UUID]

    /// The ids of terminal panels whose surface is live (legacy
    /// `surface.hasLiveSurface && surface.surface != nil`).
    public var liveSurfacePanelIds: Set<UUID>

    /// Creates a config-inheritance panel source snapshot.
    public init(
        rememberedPanelId: UUID?,
        orderedTerminalPanelIds: [UUID],
        liveSurfacePanelIds: Set<UUID>
    ) {
        self.rememberedPanelId = rememberedPanelId
        self.orderedTerminalPanelIds = orderedTerminalPanelIds
        self.liveSurfacePanelIds = liveSurfacePanelIds
    }
}
