import CMUXMobileCore
import CmuxPanes
import Foundation

/// The host seam ``MobileTerminalRPCHandler`` reaches back through to drive the
/// app-target terminal data plane it does not own.
///
/// The `mobile.terminal.*` data-plane handlers (create / replay / viewport /
/// scroll / mouse / input / paste / paste_image) and the mobile `workspace.create`
/// echo serialize and mutate live ``TabManager`` / ``Workspace`` / ``TerminalPanel``
/// state, drive the per-surface viewport-report and render-grid machinery, and
/// reuse the shared workspace-create and workspace-list bodies. Those operations
/// and the v2 param/resolution vocabulary live on ``TerminalController`` (the
/// data-plane god object being drained); this protocol exposes only the narrow
/// set the terminal handler needs, so the dispatch logic can live in its own
/// owner instead of as a block of methods on the god object. ``TerminalController``
/// conforms with one-line forwards to its existing bodies, so the wire behavior
/// is identical.
///
/// Every member is `@MainActor`: the handler, its conformer, and the terminal /
/// workspace state it drives all live on the main actor.
@MainActor
protocol MobileTerminalRPCHost: AnyObject {
    /// Whether `params[key]` is present and non-null, matching the v2 wire
    /// coercion the other mobile handlers use.
    func mobileTerminalHasNonNullParam(_ params: [String: Any], _ key: String) -> Bool

    /// UUID param accessor matching the v2 wire coercion.
    func mobileTerminalUUID(_ params: [String: Any], _ key: String) -> UUID?

    /// String param accessor (trimmed, empty-as-absent) matching the v2 wire
    /// coercion.
    func mobileTerminalStringParam(_ params: [String: Any], _ key: String) -> String?

    /// Raw string param accessor (untrimmed) matching the v2 wire coercion.
    func mobileTerminalRawStringParam(_ params: [String: Any], _ key: String) -> String?

    /// Boolean param accessor matching the v2 wire coercion.
    func mobileTerminalBoolParam(_ params: [String: Any], _ key: String) -> Bool?

    /// Resolves the target ``TabManager`` from RPC params through the legacy
    /// `v2ResolveTabManager` precedence.
    func mobileTerminalResolveTabManager(params: [String: Any]) -> TabManager?

    /// Resolves the target ``Workspace`` within a ``TabManager`` from RPC params,
    /// matching the legacy `v2ResolveWorkspace`.
    func mobileTerminalResolveWorkspace(params: [String: Any], tabManager: TabManager) -> Workspace?

    /// The shared workspace-create body (also driven by the v2 `workspace.create`
    /// command). The mobile `workspace.create` echo path forwards here, then
    /// re-lists, so the create logic stays a single source of truth.
    func mobileTerminalWorkspaceCreate(params: [String: Any], tabManager: TabManager?) -> TerminalController.V2CallResult

    /// The shared mobile workspace-list body (owned by
    /// ``MobileWorkspaceListRPCHandler``). The mobile create / terminal-create
    /// paths echo through this with the created ids so the phone snaps to the new
    /// entry, matching the legacy `v2MobileWorkspaceList` call.
    func mobileTerminalWorkspaceList(
        params: [String: Any],
        tabManager: TabManager?,
        createdWorkspaceID: String?,
        createdTerminalID: String?
    ) -> TerminalController.V2CallResult

    /// Validates the optional `workspace_id` param, returning the wire
    /// `invalid_params` ``TerminalController/V2CallResult`` when present-but-invalid
    /// (the message text stays app-side as a v2 wire literal), else `nil`.
    func mobileTerminalWorkspaceIDValidationError(params: [String: Any]) -> TerminalController.V2CallResult?

    /// Validates the `surface_id` / `terminal_id` / `tab_id` alias triple,
    /// returning the wire `invalid_params` ``TerminalController/V2CallResult`` for
    /// the invalid / conflict cases (message text stays app-side), else `nil`.
    func mobileTerminalAliasValidationError(alias: MobileTerminalAliasUUID) -> TerminalController.V2CallResult?

    /// The live render-grid frame for a terminal panel at `seq`, or `nil` when no
    /// live surface exists. Wraps the app-coupled libghostty render path
    /// (`mobileTerminalRenderGridFrame`), which stays app-side.
    func mobileTerminalRenderGridFrame(
        terminalPanel: TerminalPanel,
        surfaceID: UUID,
        seq: UInt64
    ) -> MobileTerminalRenderGridFrame?

    /// The active-screen VT export snapshot for a terminal panel (the replay
    /// fallback when no render grid is available). Wraps the app-coupled
    /// `readTerminalTextFromVTExportForSnapshot`, which stays app-side.
    func mobileTerminalVTExportSnapshot(terminalPanel: TerminalPanel) -> String?

    /// Records a paired device's reported viewport (the per-surface viewport-cap
    /// state lives app-side), matching the legacy `applyMobileViewportReport`.
    func mobileTerminalApplyViewportReport(params: [String: Any], terminalPanel: TerminalPanel, sticky: Bool)

    /// Clears a paired device's viewport report, matching the legacy
    /// `clearMobileViewportReport`.
    func mobileTerminalClearViewportReport(surfaceID: UUID, clientID: String, reason: String)

    /// Builds the scroll RPC response payload (scrollback prefetch + viewport
    /// mirror), wrapping the app-coupled `mobileTerminalScrollResponsePayload`.
    func mobileTerminalScrollPayload(
        workspaceID: UUID,
        terminalPanel: TerminalPanel,
        surfaceID: UUID,
        params: [String: Any]
    ) -> [String: Any]

    /// The panels of `workspace` in spatial (left-to-right, top-to-bottom)
    /// display order, matching the legacy `orderedPanels(in:)` the terminal-panel
    /// enumeration filters. The ordering walk stays on the god object.
    func mobileTerminalOrderedPanels(in workspace: Workspace) -> [any Panel]

    /// Localized "the input queue is full" terminal error message.
    var mobileTerminalInputQueueFullMessage: String { get }

    /// Localized "the terminal surface is unavailable" error message.
    var mobileTerminalSurfaceUnavailableMessage: String { get }

    /// Localized "the agent process exited" terminal error message.
    var mobileTerminalProcessExitedMessage: String { get }
}
