import CmuxControlSocket
import CmuxWindowing
import Foundation

/// The host seam ``MobileWorkspaceListRPCHandler`` reaches back through to drive
/// the app-target terminal data plane it does not own.
///
/// The `mobile.workspace.list` / `mobile.workspace.close` /
/// `mobile.workspace.group.set_collapsed` handlers serialize live
/// ``TabManager`` / ``Workspace`` / ``WorkspaceGroup`` state into the iOS-facing
/// payload shape and mutate group collapse / workspace-close state through the
/// same `TabManager` mutators the CLI and sidebar use. Those operations and the
/// v2 param/resolution vocabulary live on ``TerminalController`` (the data-plane
/// god object being drained); this protocol exposes only the narrow set the
/// list handler needs, so the dispatch logic can live in its own owner instead
/// of as an extension on the god object. ``TerminalController`` conforms with
/// one-line forwards to its existing bodies, so the wire behavior is identical.
///
/// Every member is `@MainActor`: the handler, its conformer, and the workspace
/// state it serializes all live on the main actor.
@MainActor
protocol MobileWorkspaceListRPCHost: AnyObject {
    /// Whether `params[key]` is present and non-null, matching the v2 wire
    /// coercion the other mobile handlers use.
    func mobileWorkspaceListHasNonNullParam(_ params: [String: Any], _ key: String) -> Bool

    /// UUID param accessor matching the v2 wire coercion.
    func mobileWorkspaceListUUID(_ params: [String: Any], _ key: String) -> UUID?

    /// Classifies the `surface_id` / `terminal_id` / `tab_id` terminal alias
    /// triple exactly as the legacy body did (missing / value / invalid /
    /// conflict).
    func mobileWorkspaceListTerminalAliasUUID(
        params: [String: Any]
    ) -> TerminalController.MobileTerminalAliasUUID

    /// Resolves the target ``TabManager`` from RPC params through the legacy
    /// `v2ResolveTabManager` precedence (workspace/window/terminal selectors,
    /// else the current scriptable window).
    func mobileWorkspaceListResolveTabManager(params: [String: Any]) -> TabManager?

    /// The window id that owns `tabManager`, matching the legacy
    /// `v2ResolveWindowId` lookup.
    func mobileWorkspaceListResolveWindowId(tabManager: TabManager?) -> UUID?

    /// The selected workspace id of the frontmost / key scriptable main window,
    /// used to mark `is_selected` in the all-windows enumeration. `nil` when no
    /// window is resolvable.
    var mobileWorkspaceListKeyWindowSelectedWorkspaceID: UUID? { get }

    /// Whether the app (and thus the all-windows enumeration) is available.
    /// `false` maps to the legacy `AppDelegate.shared == nil` guard, which fails
    /// the all-windows branch with an "unavailable" error.
    var mobileWorkspaceListAppAvailable: Bool { get }

    /// Every registered main window summary (already id-deduped), matching the
    /// legacy `AppDelegate.shared.listMainWindowSummaries()`. Empty when the app
    /// is unavailable.
    func mobileWorkspaceListMainWindowSummaries() -> [MainWindowSummary]

    /// The ``TabManager`` for a window id, matching the legacy
    /// `AppDelegate.shared.tabManagerFor(windowId:)`. `nil` when the window has
    /// no resolvable tab manager (the all-windows branch skips it).
    func mobileWorkspaceListTabManager(windowId: UUID) -> TabManager?

    /// Runs `body` synchronously on the main actor, matching the legacy
    /// `v2MainSync` hop the mutating bodies used.
    func mobileWorkspaceListMainSync<T>(_ body: @MainActor () -> T) -> T

    /// Wraps an optional value into `NSNull`-or-value exactly as the legacy
    /// `v2OrNull` payload helper did.
    func mobileWorkspaceListOrNull(_ value: Any?) -> Any

    /// Mints a v2 handle ref string for the payload, matching the legacy
    /// `v2Ref`. (Used only by the close path's error/success data.)
    func mobileWorkspaceListRef(kind: ControlHandleKind, uuid: UUID?) -> Any

    /// Trims and drops empty strings exactly as the legacy `mobileNonEmpty` did.
    func mobileWorkspaceListNonEmpty(_ raw: String?) -> String?

    /// The terminal panels of `workspace` in display order, matching the legacy
    /// `mobileTerminalPanels(in:)`.
    func mobileWorkspaceListTerminalPanels(in workspace: Workspace) -> [TerminalPanel]

    /// Adopts any title-detected coding agent in `workspace` before serializing,
    /// matching the legacy inline `adoptDetectedAgentSessions(workspace:)` call.
    func mobileWorkspaceListAdoptDetectedAgentSessions(workspace: Workspace)

    /// The app-global notification store used to source preview / unread state,
    /// matching the legacy `AppDelegate.shared?.notificationStore`. `nil` when
    /// the app is unavailable.
    var mobileWorkspaceListNotificationStore: TerminalNotificationStore? { get }

    /// Localized "this workspace can't be closed right now" message. Resolved in
    /// the app conformance so it binds to the app bundle's
    /// `Localizable.xcstrings` (not the package bundle).
    var mobileWorkspaceListCloseBlockedMessage: String { get }
}
