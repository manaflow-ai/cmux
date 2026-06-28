import Foundation

/// A param-validation rejection the Mac's mobile data-plane RPC host raises
/// before running a v2 handler.
///
/// These are the pure, app-type-free decisions ``MobileHostParamPolicy`` makes
/// about a request's identifier params. The app maps each case back to its
/// `invalid_params` wire result (the literal messages live app-side, where the
/// `V2CallResult`/`BrowserCommandResult` payload is constructed); the package
/// only decides *which* rejection applies.
public enum MobileHostRequestError: Sendable, Equatable {
    /// A present `workspace_id` param was non-null but did not resolve to a
    /// UUID. Mapped app-side to `invalid_params` / "Missing or invalid
    /// workspace_id".
    case invalidWorkspaceID

    /// A present terminal-alias param (`surface_id`/`terminal_id`/`tab_id`) was
    /// non-null but did not resolve to a UUID. Mapped app-side to
    /// `invalid_params` / "Missing or invalid terminal_id".
    case invalidTerminalID

    /// Two present terminal-alias params resolved to different UUIDs. Mapped
    /// app-side to `invalid_params` / "Conflicting terminal identifiers".
    case conflictingTerminalIDs
}
