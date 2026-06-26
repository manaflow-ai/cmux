import Foundation

// MARK: - Mobile data-plane RPC dispatch
//
// The mobile data plane speaks `MobileHostRPCRequest` / `MobileHostRPCResult`
// and dispatches directly to the app-side `v2Mobile*` bodies on
// ``TerminalController``. It deliberately does NOT route through the v2
// control-socket `ControlCommandCoordinator` (whose native result type is
// `ControlCallResult`): doing so would force a
// `MobileHostRPCRequest → ControlRequest → ControlCallResult →
// MobileHostRPCResult` type round-trip with no behavior change. The v2 control
// socket shares the same bodies through `handleMobileHost`, so the wire bytes
// stay identical across both entrypoints without a bridge here.
//
// Only the method-switch and the wire result mapping live here, on the mobile
// domain's own host service. The `v2Mobile*` bodies stay on
// ``TerminalController`` because they read/mutate live god state (TabManager,
// Workspace, ghostty surfaces, AppDelegate); they keep returning the
// `V2CallResult` mobile result type directly, with no foreign-coordinator
// bridge.
extension MobileHostService {
    /// Dispatch one decoded mobile data-plane request to the matching
    /// ``TerminalController`` `v2Mobile*` body and map the result onto the wire
    /// `MobileHostRPCResult`. `controller` is the live app-side god object whose
    /// bodies reach mutable workspace/terminal state.
    @MainActor
    func handleRPC(
        _ request: MobileHostRPCRequest,
        controller: TerminalController
    ) async -> MobileHostRPCResult {
        let result: TerminalController.V2CallResult
        switch request.method {
        case "mobile.host.status":
            result = controller.v2MobileHostStatus(params: request.params, includePrivateMetadata: false)
        case "mobile.attach_ticket.create":
            result = await controller.v2MobileAttachTicketCreate(params: request.params)
        case "mobile.workspace.list", "workspace.list":
            result = controller.v2MobileWorkspaceList(params: request.params)
        case "workspace.create":
            result = controller.v2MobileWorkspaceCreate(params: request.params)
        case "mobile.terminal.create", "terminal.create":
            result = controller.v2MobileTerminalCreate(params: request.params)
        case "mobile.terminal.input", "terminal.input":
            result = controller.v2MobileTerminalInput(params: request.params)
        case "mobile.terminal.paste", "terminal.paste":
            result = controller.v2MobileTerminalPaste(params: request.params)
        case "mobile.terminal.paste_image", "terminal.paste_image":
            result = controller.v2MobileTerminalPasteImage(params: request.params)
        case "mobile.terminal.replay", "terminal.replay":
            result = controller.v2MobileTerminalReplay(params: request.params)
        case "mobile.terminal.viewport", "terminal.viewport":
            result = controller.v2MobileTerminalViewport(params: request.params)
        case "mobile.terminal.scroll", "terminal.scroll":
            result = controller.v2MobileTerminalScroll(params: request.params)
        case "mobile.terminal.mouse", "terminal.mouse":
            result = controller.v2MobileTerminalMouse(params: request.params)
        case "workspace.action":
            result = controller.v2MobileWorkspaceAction(params: request.params)
        case let method where method.hasPrefix("mobile.chat."):
            result = await controller.v2MobileChatDispatch(method: method, params: request.params)
        case "workspace.close":
            result = controller.v2MobileWorkspaceClose(params: request.params)
        case "workspace.group.collapse":
            result = controller.v2MobileWorkspaceGroupSetCollapsed(params: request.params, isCollapsed: true)
        case "workspace.group.expand":
            result = controller.v2MobileWorkspaceGroupSetCollapsed(params: request.params, isCollapsed: false)
        case "notification.dismiss":
            result = controller.v2MobileNotificationDismiss(params: request.params)
        case "notification.reconcile":
            result = controller.v2MobileNotificationReconcile(params: request.params)
        case "dogfood.feedback.submit":
            result = await controller.v2MobileDogfoodFeedbackSubmit(params: request.params)
        default:
            result = .err(code: "method_not_found", message: "Unknown mobile method", data: [
                "method": request.method
            ])
        }
        return mobileHostResult(result)
    }

    /// Map an app-side ``TerminalController/V2CallResult`` onto the mobile wire
    /// ``MobileHostRPCResult``, scrubbing internal-error details so an
    /// `internal_error` never leaks an implementation message or payload to the
    /// phone.
    private func mobileHostResult(_ result: TerminalController.V2CallResult) -> MobileHostRPCResult {
        switch result {
        case let .ok(payload):
            return .ok(payload)
        case let .err(code, message, data):
            let safeMessage = code == "internal_error" ? "Mobile host operation failed" : message
            let safeData = code == "internal_error" ? nil : data
            return .failure(MobileHostRPCError(code: code, message: safeMessage, data: safeData))
        }
    }
}
