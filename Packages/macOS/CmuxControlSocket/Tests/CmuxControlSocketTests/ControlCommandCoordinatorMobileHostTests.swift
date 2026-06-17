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
    /// The method passed to ``controlMobileChatDispatch(method:params:)``.
    private(set) var lastChatMethod: String?
    /// The `isCollapsed` flag passed to the workspace-group witness.
    private(set) var lastIsCollapsed: Bool?

    private func record(_ marker: String, _ params: [String: JSONValue]) -> ControlCallResult {
        lastMarker = marker
        lastParams = params
        return .ok(.object(["marker": .string(marker)]))
    }

    func controlMobileHostStatus(params: [String: JSONValue]) -> ControlCallResult {
        record("host.status.private", params)
    }

    func controlMobileHostStatusPublic(params: [String: JSONValue]) -> ControlCallResult {
        record("host.status.public", params)
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

    func controlMobileChatSessionsDump() -> ControlCallResult {
        record("chat.sessions.dump", [:])
    }

    func controlMobileAttachTicketCreate(params: [String: JSONValue]) async -> ControlCallResult {
        record("attach_ticket.create", params)
    }

    func controlMobileTerminalPasteImage(params: [String: JSONValue]) -> ControlCallResult {
        record("terminal.paste_image", params)
    }

    func controlMobileWorkspaceCreate(params: [String: JSONValue]) -> ControlCallResult {
        record("workspace.create", params)
    }

    func controlMobileWorkspaceAction(params: [String: JSONValue]) -> ControlCallResult {
        record("workspace.action", params)
    }

    func controlMobileChatDispatch(method: String, params: [String: JSONValue]) async -> ControlCallResult {
        lastChatMethod = method
        return record("chat.dispatch", params)
    }

    func controlMobileWorkspaceClose(params: [String: JSONValue]) -> ControlCallResult {
        record("workspace.close", params)
    }

    func controlMobileWorkspaceGroupSetCollapsed(
        params: [String: JSONValue],
        isCollapsed: Bool
    ) -> ControlCallResult {
        lastIsCollapsed = isCollapsed
        return record("workspace.group.set_collapsed", params)
    }

    func controlMobileNotificationDismiss(params: [String: JSONValue]) -> ControlCallResult {
        record("notification.dismiss", params)
    }

    func controlMobileNotificationReconcile(params: [String: JSONValue]) -> ControlCallResult {
        record("notification.reconcile", params)
    }

    func controlMobileDogfoodFeedbackSubmit(params: [String: JSONValue]) async -> ControlCallResult {
        record("dogfood.feedback.submit", params)
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

    @Test func v2SurfaceRoutesChatSessionsDumpThroughSeam() {
        let (coordinator, context) = makeCoordinator()
        #expect(coordinator.handle(request("chat.sessions.dump")) != nil)
        #expect(context.lastMarker == "chat.sessions.dump")
    }

    @Test func v2SurfaceUsesPrivateHostStatusVariant() {
        let (coordinator, context) = makeCoordinator()
        #expect(coordinator.handle(request("mobile.host.status")) != nil)
        // The v2 control socket path includes private metadata.
        #expect(context.lastMarker == "host.status.private")
    }

    @Test func v2SurfaceMobileHostHandlerIgnoresDataPlaneOnlyVerbs() {
        let (coordinator, context) = makeCoordinator()
        // The mobile-host v2 dispatcher must NOT own the data-plane-only verbs
        // (`mobile.chat.*`, `dogfood.feedback.submit`, the mobile workspace
        // wrappers). `handleMobileHost` returns nil for them so they never touch a
        // mobile-host seam witness on the v2 control socket. (Other coordinator
        // domains may still own some of these method names — e.g. the workspace
        // domain owns `workspace.close` — so this asserts the mobile-host handler
        // specifically, not the umbrella `handle(_:)`.)
        for method in [
            "mobile.chat.sessions",
            "dogfood.feedback.submit",
            "mobile.attach_ticket.create",
            "workspace.action",
        ] {
            #expect(coordinator.handleMobileHost(request(method)) == nil, "for \(method)")
        }
        #expect(context.lastMarker == nil)
    }

    // MARK: - handleMobileHostRPC (mobile data-plane surface)

    @Test func rpcUsesPublicHostStatusVariant() async {
        let (coordinator, context) = makeCoordinator()
        let result = await coordinator.handleMobileHostRPC(request("mobile.host.status"))
        #expect(result != nil)
        // The data-plane RPC path omits private metadata.
        #expect(context.lastMarker == "host.status.public")
    }

    @Test func rpcRoutesWorkspaceListBareAlias() async {
        let (coordinator, context) = makeCoordinator()
        // The bare `workspace.list` alias is RPC-only (the v2 surface keeps it on
        // the legacy v2WorkspaceList).
        _ = await coordinator.handleMobileHostRPC(request("workspace.list"))
        #expect(context.lastMarker == "workspace.list")
        // The bare alias is RPC-only for the mobile-host handler: the v2
        // mobile-host dispatcher does not route it (the v2 surface keeps
        // `workspace.list` on the workspace domain / legacy v2WorkspaceList).
        #expect(coordinator.handleMobileHost(request("workspace.list")) == nil)
    }

    @Test func rpcRoutesChatPrefixThroughDispatchSeam() async {
        let (coordinator, context) = makeCoordinator()
        _ = await coordinator.handleMobileHostRPC(request("mobile.chat.history"))
        #expect(context.lastMarker == "chat.dispatch")
        #expect(context.lastChatMethod == "mobile.chat.history")
    }

    @Test func rpcRoutesWorkspaceGroupCollapseAndExpand() async {
        let (coordinator, context) = makeCoordinator()
        _ = await coordinator.handleMobileHostRPC(request("workspace.group.collapse"))
        #expect(context.lastMarker == "workspace.group.set_collapsed")
        #expect(context.lastIsCollapsed == true)
        _ = await coordinator.handleMobileHostRPC(request("workspace.group.expand"))
        #expect(context.lastIsCollapsed == false)
    }

    @Test func rpcRoutesEachDataPlaneVerbToItsSeam() async {
        let (coordinator, context) = makeCoordinator()
        let expectations: [(method: String, marker: String)] = [
            ("mobile.attach_ticket.create", "attach_ticket.create"),
            ("workspace.create", "workspace.create"),
            ("mobile.terminal.paste_image", "terminal.paste_image"),
            ("terminal.paste_image", "terminal.paste_image"),
            ("workspace.action", "workspace.action"),
            ("workspace.close", "workspace.close"),
            ("notification.dismiss", "notification.dismiss"),
            ("notification.reconcile", "notification.reconcile"),
            ("dogfood.feedback.submit", "dogfood.feedback.submit"),
            ("mobile.terminal.input", "terminal.input"),
            ("terminal.mouse", "terminal.mouse"),
        ]
        for expectation in expectations {
            let result = await coordinator.handleMobileHostRPC(request(expectation.method))
            #expect(result != nil, "expected \(expectation.method) to be handled")
            #expect(context.lastMarker == expectation.marker, "for \(expectation.method)")
        }
    }

    @Test func rpcReturnsNilForUnknownMethod() async {
        let (coordinator, _) = makeCoordinator()
        let result = await coordinator.handleMobileHostRPC(request("totally.unknown.method"))
        #expect(result == nil)
    }

    @Test func rpcForwardsParamsVerbatim() async {
        let (coordinator, context) = makeCoordinator()
        let params: [String: JSONValue] = [
            "workspace_id": .string("abc"),
            "text": .string("hello"),
            "count": .int(3),
        ]
        _ = await coordinator.handleMobileHostRPC(request("mobile.terminal.input", params))
        #expect(context.lastParams == params)
    }
}
