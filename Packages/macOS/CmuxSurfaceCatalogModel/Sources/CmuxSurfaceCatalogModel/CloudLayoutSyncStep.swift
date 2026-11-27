import Foundation

/// The next daemon mutation that moves a machine workspace toward a ``CloudLayoutSyncTree``.
///
/// ``CloudLayoutSyncPlanner`` produces one step from one snapshot. The caller performs
/// it, reads a fresh snapshot and plans again, so every step is fenced by the revision
/// it was planned against and a concurrent edit from another client is re-read, never
/// overwritten from a stale plan.
public enum CloudLayoutSyncStep: Equatable, Sendable {
    /// The machine already matches the requested tree.
    case done
    /// Tab membership differs, for example while a created terminal has not been
    /// projected yet. Syncing now could strand a tab, so the caller tries again later.
    case notReady(String)
    /// The workspace uses a shape this client does not write (several screens,
    /// scrolling viewports or stacks). The machine's layout is left untouched.
    case unsupported(String)
    /// Moves one tab to `index` of an existing pane. Moving a pane's last tab away
    /// removes that pane on the machine.
    case moveTab(tabID: String, target: CloudTuiTerminalProjectionTarget)
    /// Splits `paneID` so a native pane that has no machine pane gets one. The daemon
    /// cannot create an empty pane, so the split starts a scratch terminal that a later
    /// ``closeScratch(tabID:terminalID:)`` step removes.
    case splitPane(paneID: String)
    /// Closes a scratch terminal started by ``splitPane(paneID:)`` once its pane holds
    /// a real tab or is no longer needed.
    case closeScratch(tabID: String, terminalID: String)
    /// Applies the whole layout document (tree shape, directions, ratios and selected
    /// tabs) once pane and tab membership already match. The payload is the JSON
    /// `LayoutDocument` for `workspace.layout.apply`.
    case applyLayout(Data)
}
