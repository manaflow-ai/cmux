import Foundation

extension AgentPaneModel {
    /// The missing-access card's calls (``AgentPaneAccessRequest``). Never for a chat on another
    /// machine: its harness, routes and Keychain are not this Mac's. A sheet or a payment page opens
    /// only on the person's click. A key added from a page with no chat yet becomes its harness
    /// family's default route, so the chat it starts sends it (a chat binds its own in the page).
    func respondToAccess(_ request: AgentPaneAccessRequest) async -> [String: Any] {
        guard let access, !remoteChat else { return Self.unsupported(request.method) }
        if request.needsGesture, !transport.gestures.consume() {
            return AgentPaneReply.failure(code: "access.gesture_required", message: Self.shellGestureMessage)
        }
        let socket = transport.acpmuxSocket
        let reply = await access.respond(to: request, acpmuxSocket: socket)
        if case .addKey(_, let family?) = request, sessionId == nil, let socket,
           case .success(let value) = reply, let route = value["routeId"]?.stringValue {
            _ = try? await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/route/default.set",
                                                   params: ["scope": "family:\(family)", "routeId": route],
                                                   deadline: .seconds(10), detailed: true)
        }
        return reply.page
    }
}
