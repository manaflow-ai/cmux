#if DEBUG
public import Foundation

/// The live-state seam for the Debug menu's terminal-tab openers.
///
/// ``DebugTerminalActionsCoordinator`` owns the orchestration behind the
/// `openDebugScrollbackTab` / `openDebugLoremTab` /
/// `openDebugAgentSessionReact` / `openDebugAgentSessionSolid` /
/// `openDebugColorComparisonWorkspaces` menu actions: the scrollback/lorem
/// payload selection, the React-vs-Solid renderer dispatch, and the
/// color-comparison create-or-reuse loop. None of that touches an app type. The
/// operations that *do* touch live state (creating a workspace tab, reading the
/// Ghostty scrollback limit, streaming text into a tab once its surface is
/// ready, creating an agent-session surface, reading/setting tab titles and
/// colors, projecting the tab-color palette) cannot cross the package boundary,
/// so the app target conforms this protocol and the coordinator calls back into
/// it.
///
/// The coordinator never names a `Workspace`, a `TabManager`, an
/// `AgentSessionRendererKind`, or a `WorkspaceTabColorEntry`: it addresses
/// workspaces by their `UUID` and speaks only in package value types
/// (``DebugAgentSessionRendererKind``, ``DebugColorComparisonEntry``,
/// ``DebugTerminalTabSnapshot``). The host keeps the mapping from a `UUID` back
/// to its live workspace.
///
/// The seam is `#if DEBUG` only, matching the legacy menu actions it was
/// extracted from.
///
/// Isolation: `@MainActor`, because every operation reads and mutates
/// main-actor workspace / tab / terminal-surface state.
@MainActor
public protocol DebugTerminalActionsHosting: AnyObject {
    /// Whether the openers can run right now. Mirrors the legacy
    /// `guard let tabManager` precondition shared by every action: `false` when
    /// there is no live tab manager, in which case the coordinator does nothing.
    var canRunDebugTerminalActions: Bool { get }

    /// The terminal's configured Ghostty scrollback limit in bytes, read for the
    /// scrollback opener (legacy `GhosttyConfig.load().scrollbackLimit`).
    var ghosttyScrollbackLimit: Int { get }

    /// Creates a new workspace tab and returns its id, or `nil` if no tab
    /// manager is live (legacy `tabManager.addTab()`).
    func addDebugTab() -> UUID?

    /// Streams `text` into the workspace identified by `tabId` once its terminal
    /// surface is ready (legacy `sendTextWhenReady(_:to:)`). The
    /// `String(localized:)`-free payload is built by the coordinator; the
    /// surface-readiness send stays app-side behind this seam.
    func sendDebugText(_ text: String, toTab tabId: UUID)

    /// Opens an agent session with `rendererKind` in the currently selected
    /// workspace's focused pane, doing nothing when there is no selected
    /// workspace or pane (legacy private `openDebugAgentSession(rendererKind:)`).
    func openDebugAgentSession(rendererKind: DebugAgentSessionRendererKind)

    /// A snapshot of every live workspace tab's id and custom title, used to
    /// reuse existing color-comparison workspaces (legacy iteration over
    /// `tabManager.tabs`).
    func debugTabSnapshots() -> [DebugTerminalTabSnapshot]

    /// Sets the custom title of the workspace identified by `tabId` (legacy
    /// `tabManager.setCustomTitle(tabId:title:)`).
    func setDebugTabCustomTitle(tabId: UUID, title: String)

    /// Sets the tab color of the workspace identified by `tabId` to `hex`
    /// (legacy `tabManager.setTabColor(tabId:color:)`).
    func setDebugTabColor(tabId: UUID, hex: String)

    /// The workspace tab-color palette projected onto package value types
    /// (legacy `WorkspaceTabColorSettings.palette()`).
    func debugColorComparisonPalette() -> [DebugColorComparisonEntry]
}
#endif
