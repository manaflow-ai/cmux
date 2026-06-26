import CMUXMobileCore
import Foundation

/// The host seam ``MobileTerminalRPCHandler`` reaches back through to drive the
/// app-target terminal data plane it does not own.
///
/// The `mobile.terminal.*` data-plane handlers (create / replay / viewport /
/// scroll / mouse / input / paste_image / paste) and the mobile workspace-create
/// echo serialize and mutate live ``TabManager`` / ``Workspace`` / ``TerminalPanel``
/// state and the ghostty surface. The v2 param-coercion and resolution
/// vocabulary, the shared validation helpers, the viewport-report state machine,
/// the render-grid / scroll-payload projection, and the ghostty / pasteboard /
/// agent-detection reads all live on ``TerminalController`` (the data-plane god
/// object being drained); this protocol exposes only the narrow set the terminal
/// handler needs, so the dispatch logic can live in its own owner instead of as
/// an extension on the god object. ``TerminalController`` conforms with one-line
/// forwards to its existing bodies, so the wire behavior is identical.
///
/// Every member is `@MainActor`: the handler, its conformer, and the workspace /
/// surface state it drives all live on the main actor. Localized terminal error
/// messages are resolved in the app conformance so they bind to the app bundle's
/// `Localizable.xcstrings` (not the package bundle).
@MainActor
protocol MobileTerminalRPCHost: AnyObject {
    /// Resolves the target ``TabManager`` from RPC params through the legacy
    /// `v2ResolveTabManager` precedence (workspace/window/terminal selectors,
    /// else the current scriptable window).
    func mobileTerminalResolveTabManager(params: [String: Any]) -> TabManager?

    /// Resolves the target ``Workspace`` within `tabManager` from RPC params,
    /// matching the legacy `v2ResolveWorkspace(params:tabManager:)`.
    func mobileTerminalResolveWorkspace(params: [String: Any], tabManager: TabManager) -> Workspace?

    /// Resolves a workspace and (optionally) its target terminal surface from RPC
    /// params, materializing a lazily-created surface when `requireTerminal` is
    /// set. Returns `nil` when the params do not resolve. Matches the legacy
    /// `mobileResolveWorkspaceAndSurface(params:requireTerminal:)` (the
    /// `tabManager` member of its tuple is unused by the terminal data plane and
    /// is dropped here).
    func mobileTerminalResolveWorkspaceAndSurface(
        params: [String: Any],
        requireTerminal: Bool
    ) -> (workspace: Workspace, surfaceId: UUID?)?

    /// Present-but-malformed `workspace_id` rejection, matching the legacy
    /// `mobileWorkspaceIDValidationError`. `nil` when the param is absent or
    /// valid.
    func mobileTerminalWorkspaceIDValidationError(params: [String: Any]) -> TerminalController.V2CallResult?

    /// Present-but-malformed / conflicting terminal-alias rejection, matching the
    /// legacy `mobileTerminalAliasValidationError`. `nil` when the alias is absent
    /// or valid.
    func mobileTerminalAliasValidationError(params: [String: Any]) -> TerminalController.V2CallResult?

    /// The shared workspace-create implementation, matching the legacy
    /// `v2WorkspaceCreate(params:tabManager:)` the mobile create path drives.
    func mobileTerminalWorkspaceCreate(
        params: [String: Any],
        tabManager: TabManager
    ) -> TerminalController.V2CallResult

    /// The iOS-facing workspace/terminal list echo, matching the legacy
    /// `v2MobileWorkspaceList(params:tabManager:createdWorkspaceID:createdTerminalID:)`.
    func mobileTerminalWorkspaceList(
        params: [String: Any],
        tabManager: TabManager?,
        createdWorkspaceID: String?,
        createdTerminalID: String?
    ) -> TerminalController.V2CallResult

    /// The default pane to spawn into for a fresh mobile terminal, matching the
    /// legacy `workspace.bonsplitController.focusedPaneId ?? .allPaneIds.first`.
    func mobileTerminalDefaultPaneId(in workspace: Workspace) -> UUID?

    /// The mobile render-grid frame for a surface at `seq`, matching the legacy
    /// `mobileTerminalRenderGridFrame(terminalPanel:surfaceID:seq:)` (distinct
    /// seam name so the witness can forward to that method without recursing).
    func mobileTerminalReplayRenderGridFrame(
        terminalPanel: TerminalPanel,
        surfaceID: UUID,
        seq: UInt64
    ) -> MobileTerminalRenderGridFrame?

    /// The mobile scroll response payload (viewport + optional prefetch grid),
    /// matching the legacy `mobileTerminalScrollResponsePayload(...)` (distinct
    /// seam name so the witness can forward without recursing).
    func mobileTerminalScrollPayload(
        workspaceID: UUID,
        terminalPanel: TerminalPanel,
        surfaceID: UUID,
        params: [String: Any]
    ) -> [String: Any]

    /// The active-screen VT-export snapshot text for the replay fallback,
    /// matching the legacy `readTerminalTextFromVTExportForSnapshot(terminalPanel:
    /// bindingAction: "write_active_file:copy,vt", lineLimit: nil,
    /// normalizeLineEndings: false)`.
    func mobileTerminalActiveVTExportSnapshot(terminalPanel: TerminalPanel) -> String?

    /// The live ghostty grid size for a surface (already clamped to >= 1),
    /// matching the legacy `ghostty_surface_size` read behind
    /// `liveSurfaceForGhosttyAccess(reason:)`. `nil` when no live surface exists.
    func mobileTerminalLiveGridSize(
        terminalPanel: TerminalPanel,
        reason: String
    ) -> (columns: Int, rows: Int)?

    /// Records a paired device's reported viewport, matching the legacy
    /// `applyMobileViewportReport(params:terminalPanel:sticky:)`.
    func mobileTerminalApplyViewportReport(
        params: [String: Any],
        terminalPanel: TerminalPanel,
        sticky: Bool
    )

    /// Clears one client's viewport report for a surface, matching the legacy
    /// `clearMobileViewportReport(surfaceID:clientID:reason:)`.
    func mobileTerminalClearViewportReport(surfaceID: UUID, clientID: String, reason: String)

    /// Materializes a pasted image to a temp file and returns the shell-escaped
    /// path, matching the legacy `GhosttyApp.terminalPasteboard.saveImageData(_:
    /// fileExtension:)`. `nil` when the payload was empty or too large.
    func mobileTerminalSaveImageData(_ data: Data, format: String) -> String?

    /// Whether the resolved surface is running Claude Code, matching the legacy
    /// `TextBoxAgentDetection.isClaudeCode(context:
    /// WorkspaceContentView.terminalAgentContext(panel:workspace:))` agent-aware
    /// submit-key upgrade.
    func mobileTerminalIsClaudeCode(panel: TerminalPanel, workspace: Workspace) -> Bool

    /// Raw string param accessor (untrimmed) matching the v2 wire coercion.
    func mobileTerminalRawString(_ params: [String: Any], _ key: String) -> String?

    /// String param accessor (trimmed, empty-as-absent) matching the v2 wire
    /// coercion.
    func mobileTerminalString(_ params: [String: Any], _ key: String) -> String?

    /// Boolean param accessor matching the v2 wire coercion.
    func mobileTerminalBool(_ params: [String: Any], _ key: String) -> Bool?

    /// Localized "the input queue is full" terminal error message.
    var mobileTerminalInputQueueFullMessage: String { get }

    /// Localized "the terminal surface is unavailable" error message.
    var mobileTerminalSurfaceUnavailableMessage: String { get }

    /// Localized "the agent process exited" terminal error message.
    var mobileTerminalProcessExitedMessage: String { get }
}
