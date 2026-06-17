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
/// bare `workspace.list` stays on the legacy `v2WorkspaceList`), the
/// `mobile.terminal.*` verbs each with their bare `terminal.*` alias, plus
/// `mobile.terminal.paste` / `terminal.paste` and the local debug
/// `chat.sessions.dump`. The worker-lane `mobile.attach_ticket.create` and the
/// mobile-data-plane-only verbs are dispatched by ``handleMobileHostRPC(_:)``
/// instead (they never reach `processV2Command`).
extension ControlCommandCoordinator {
    /// Dispatches the mobile-host methods the v2 control socket
    /// (`processV2Command`) routes here; returns `nil` for anything else so the
    /// core `handle(_:)` can fall through to the legacy app-side dispatcher.
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
        case "mobile.terminal.paste", "terminal.paste":
            return context?.controlMobileTerminalPaste(params: request.params)
        case "chat.sessions.dump":
            return context?.controlMobileChatSessionsDump()
        default:
            return nil
        }
    }

    /// Dispatches the full mobile data-plane RPC surface (`mobileHostHandleRPC`).
    /// This is the superset of ``handleMobileHost(_:)``: it also answers the
    /// data-plane-only verbs (`mobile.attach_ticket.create`, paste-image, the
    /// `workspace.create`/`action`/`close`/`group.*` mobile wrappers, the
    /// `mobile.chat.*` agent-chat verbs, the `notification.dismiss`/`reconcile`
    /// dismiss-sync verbs, and `dogfood.feedback.submit`) that the phone reaches
    /// only through the data plane, never through `processV2Command`.
    ///
    /// Returns `nil` for an unknown method so the app-side handler can produce its
    /// `method_not_found` error verbatim.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a mobile-host RPC method.
    public func handleMobileHostRPC(_ request: ControlRequest) async -> ControlCallResult? {
        guard let context else { return nil }
        let params = request.params
        switch request.method {
        case "mobile.host.status":
            return context.controlMobileHostStatusPublic(params: params)
        case "mobile.attach_ticket.create":
            return await context.controlMobileAttachTicketCreate(params: params)
        case "mobile.workspace.list", "workspace.list":
            return context.controlMobileWorkspaceList(params: params)
        case "workspace.create":
            return context.controlMobileWorkspaceCreate(params: params)
        case "mobile.terminal.create", "terminal.create":
            return context.controlMobileTerminalCreate(params: params)
        case "mobile.terminal.input", "terminal.input":
            return context.controlMobileTerminalInput(params: params)
        case "mobile.terminal.paste", "terminal.paste":
            return context.controlMobileTerminalPaste(params: params)
        case "mobile.terminal.paste_image", "terminal.paste_image":
            return context.controlMobileTerminalPasteImage(params: params)
        case "mobile.terminal.replay", "terminal.replay":
            return context.controlMobileTerminalReplay(params: params)
        case "mobile.terminal.viewport", "terminal.viewport":
            return context.controlMobileTerminalViewport(params: params)
        case "mobile.terminal.scroll", "terminal.scroll":
            return context.controlMobileTerminalScroll(params: params)
        case "mobile.terminal.mouse", "terminal.mouse":
            return context.controlMobileTerminalMouse(params: params)
        case "workspace.action":
            return context.controlMobileWorkspaceAction(params: params)
        case let method where method.hasPrefix("mobile.chat."):
            return await context.controlMobileChatDispatch(method: method, params: params)
        case "workspace.close":
            return context.controlMobileWorkspaceClose(params: params)
        case "workspace.group.collapse":
            return context.controlMobileWorkspaceGroupSetCollapsed(params: params, isCollapsed: true)
        case "workspace.group.expand":
            return context.controlMobileWorkspaceGroupSetCollapsed(params: params, isCollapsed: false)
        case "notification.dismiss":
            return context.controlMobileNotificationDismiss(params: params)
        case "notification.reconcile":
            return context.controlMobileNotificationReconcile(params: params)
        case "dogfood.feedback.submit":
            return await context.controlMobileDogfoodFeedbackSubmit(params: params)
        default:
            return nil
        }
    }
}
