public import Foundation

/// The identify-domain slice of the control-command seam (a constituent of the
/// ``ControlCommandContext`` umbrella): the live window/workspace/pane/surface
/// graph reads plus the app-bundle paths that back `system.identify`. The
/// coordinator owns the payload-dict shaping and `kind:N` ref minting (see
/// ``ControlCommandCoordinator/identify(params:)``); the witness performs only
/// snapshot reads, never mutating app state.
///
/// `system.identify` also feeds the window-routing parse shared with
/// `system.tree` (``ControlCommandCoordinator/systemWindowRouting(_:)``) and the
/// worker-lane `system.top` / `system.memory` base payload, so this seam is the
/// single source for the live identify reads.
///
/// Every method is `@MainActor`: the conformer (the interim composition owner)
/// and the coordinator both live on the main actor, so these are plain
/// in-isolation reads.
@MainActor
public protocol ControlIdentifyContext: AnyObject {
    /// The server's current socket path (`socketServer.currentSocketPath`), for
    /// the identify payload's `socket_path` field.
    func controlIdentifySocketPath() -> String

    /// Resolves the focused-location identity for the identify params.
    ///
    /// - Parameter params: The identify params (`window_id`, …) used to resolve
    ///   the target tab manager.
    /// - Returns: The focused snapshot, or `nil` when no tab manager resolves
    ///   (the legacy early-return with null `focused` / `caller`).
    func controlIdentifyFocused(params: [String: JSONValue]) -> ControlIdentifyFocusedSnapshot?

    /// Validates a caller-provided workspace/surface location against the live
    /// graph, falling back to the params' tab manager exactly as the legacy
    /// caller block did (`AppDelegate.tabManagerFor(tabId:) ?? resolved`).
    ///
    /// - Parameters:
    ///   - params: The identify params, used for the tab-manager fallback.
    ///   - workspaceID: The caller workspace id.
    ///   - surfaceID: The caller surface id (`surface_id` / `tab_id`), if any.
    /// - Returns: The caller snapshot, or `nil` when the workspace does not
    ///   resolve.
    func controlIdentifyCaller(
        params: [String: JSONValue],
        workspaceID: UUID,
        surfaceID: UUID?
    ) -> ControlIdentifyCallerSnapshot?

    /// The app-bundle path reads for the identify payload tail.
    func controlIdentifyBundle() -> ControlIdentifyBundleSnapshot
}
