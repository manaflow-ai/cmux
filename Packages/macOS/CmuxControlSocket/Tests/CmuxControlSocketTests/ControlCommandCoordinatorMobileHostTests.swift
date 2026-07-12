import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlCommandContext`` for driving the mobile-host
/// coordinator dispatch without the app target. Each witness records the verb it
/// was routed to (and its params) and returns a recognizable `ControlCallResult`
/// so a test can assert the coordinator dispatched the right seam method.
@MainActor
private final class FakeMobileHostControlCommandContext: ControlCommandContext {
    /// The last verb each routed witness recorded, in `marker` form.
    private(set) var lastMarker: String?
    /// The params the last routed witness received.
    private(set) var lastParams: [String: JSONValue]?

    private func record(_ marker: String, _ params: [String: JSONValue]) -> ControlCallResult {
        lastMarker = marker
        lastParams = params
        return .ok(.object(["marker": .string(marker)]))
    }

    func controlMobileHostStatus(params: [String: JSONValue]) -> ControlCallResult {
        record("host.status.private", params)
    }

    func controlMobileWorkspaceList(params: [String: JSONValue]) -> ControlCallResult {
        record("workspace.list", params)
    }

    func controlMobileTerminalCreate(params: [String: JSONValue]) -> ControlCallResult {
        record("terminal.create", params)
    }

    func controlMobileTerminalInput(params: [String: JSONValue]) -> ControlCallResult {
        record("terminal.input", params)
    }

    func controlMobileTerminalReplay(params: [String: JSONValue]) -> ControlCallResult {
        record("terminal.replay", params)
    }

    func controlMobileTerminalViewport(params: [String: JSONValue]) -> ControlCallResult {
        record("terminal.viewport", params)
    }

    func controlMobileTerminalScroll(params: [String: JSONValue]) -> ControlCallResult {
        record("terminal.scroll", params)
    }

    func controlMobileTerminalMouse(params: [String: JSONValue]) -> ControlCallResult {
        record("terminal.mouse", params)
    }

    func controlMobileTerminalPaste(params: [String: JSONValue]) -> ControlCallResult {
        record("terminal.paste", params)
    }

}

@MainActor
@Suite("ControlCommandCoordinator mobile-host domain")
struct ControlCommandCoordinatorMobileHostTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeMobileHostControlCommandContext) {
        let context = FakeMobileHostControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: .int(1), method: method, params: params)
    }

    // MARK: - handleMobileHost (processV2Command surface)

    @Test func v2SurfaceRoutesPasteAndAliasThroughSeam() {
        let (coordinator, context) = makeCoordinator()
        #expect(coordinator.handle(request("mobile.terminal.paste")) != nil)
        #expect(context.lastMarker == "terminal.paste")
        #expect(coordinator.handle(request("terminal.paste")) != nil)
        #expect(context.lastMarker == "terminal.paste")
    }

    @Test func v2SurfaceUsesPrivateHostStatusVariant() {
        let (coordinator, context) = makeCoordinator()
        #expect(coordinator.handle(request("mobile.host.status")) != nil)
        // The v2 control socket path includes private metadata.
        #expect(context.lastMarker == "host.status.private")
    }

    @Test func v2SurfaceForwardsParamsVerbatim() {
        let (coordinator, context) = makeCoordinator()
        let params: [String: JSONValue] = [
            "workspace_id": .string("abc"),
            "text": .string("hello"),
            "count": .int(3),
        ]
        #expect(coordinator.handle(request("mobile.terminal.input", params)) != nil)
        #expect(context.lastMarker == "terminal.input")
        #expect(context.lastParams == params)
    }

    @Test func v2SurfaceMobileHostHandlerIgnoresDataPlaneOnlyVerbs() {
        let (coordinator, context) = makeCoordinator()
        // The mobile-host v2 dispatcher must NOT own the data-plane-only verbs
        // (`dogfood.feedback.submit` and the mobile workspace wrappers). The
        // phone reaches those only through the mobile data-plane RPC
        // (`TerminalController.mobileHostHandleRPC`), which dispatches its
        // `v2Mobile*` bodies directly and never transits this coordinator.
        // `handleMobileHost` returns nil for them so they never touch a mobile-host
        // seam witness on the v2 control socket. (Other coordinator domains may
        // still own some of these method names — e.g. the workspace domain owns
        // `workspace.close` — so this asserts the mobile-host handler specifically,
        // not the umbrella `handle(_:)`.)
        for method in [
            "dogfood.feedback.submit",
            "mobile.attach_ticket.create",
            "workspace.action",
            "workspace.create",
            "workspace.close",
            "notification.dismiss",
            "notification.reconcile",
            "mobile.terminal.paste_image",
        ] {
            #expect(coordinator.handleMobileHost(request(method)) == nil, "for \(method)")
        }
        #expect(context.lastMarker == nil)
    }

    @Test func v2SurfaceMobileHostHandlerIgnoresBareWorkspaceListAlias() {
        let (coordinator, context) = makeCoordinator()
        // The bare `workspace.list` alias stays on the workspace domain / legacy
        // `v2WorkspaceList`: the v2 mobile-host dispatcher does not route it.
        #expect(coordinator.handleMobileHost(request("workspace.list")) == nil)
        #expect(context.lastMarker == nil)
    }
}
