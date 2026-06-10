internal import Foundation

/// The mobile-host domain (`mobile.*` / `terminal.*`), lifted byte-faithfully
/// from the former `TerminalController.v2Mobile*` bodies that `processV2Command`
/// dispatched.
///
/// These bodies build deeply nested, app-state-derived Foundation payloads and
/// resolve their target through the legacy `v2ResolveTabManager` precedence, and
/// none of them mint `kind:N` refs. So each coordinator method is a thin
/// pass-through to its ``ControlMobileHostContext`` seam method, which runs the
/// exact legacy body app-side and bridges the resulting Foundation payload to a
/// ``JSONValue`` — the wire bytes are identical. The localized terminal-input
/// error strings resolve against the app bundle in the conformance, so moving
/// the dispatch here does not change them.
///
/// The aliases mirror `processV2Command` exactly: `mobile.workspace.list` (the
/// bare `workspace.list` stays on the legacy `v2WorkspaceList`), and the
/// `mobile.terminal.*` verbs each with their bare `terminal.*` alias. The
/// worker-lane `mobile.attach_ticket.create` and the mobile-data-plane-only
/// verbs are deliberately not handled here.
extension ControlCommandCoordinator {
    /// Dispatches the mobile-host methods this coordinator owns; returns `nil`
    /// for anything else so the core `handle(_:)` can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a mobile-host method.
    func handleMobileHost(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "mobile.host.status":
            return context?.controlMobileHostStatus(params: request.params)
        case "mobile.workspace.list":
            return context?.controlMobileWorkspaceList(params: request.params)
        case "mobile.terminal.create", "terminal.create":
            return context?.controlMobileTerminalCreate(params: request.params)
        case "mobile.terminal.input", "terminal.input":
            return context?.controlMobileTerminalInput(params: request.params)
        case "mobile.terminal.replay", "terminal.replay":
            return context?.controlMobileTerminalReplay(params: request.params)
        case "mobile.terminal.viewport", "terminal.viewport":
            return context?.controlMobileTerminalViewport(params: request.params)
        case "mobile.terminal.scroll", "terminal.scroll":
            return context?.controlMobileTerminalScroll(params: request.params)
        case "mobile.terminal.mouse", "terminal.mouse":
            return context?.controlMobileTerminalMouse(params: request.params)
        default:
            return nil
        }
    }
}
