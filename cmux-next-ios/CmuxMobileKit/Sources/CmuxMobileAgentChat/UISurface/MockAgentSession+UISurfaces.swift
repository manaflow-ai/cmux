// DEBUG and Demo builds only: mock content is never compiled into Production.
#if DEBUG
import Foundation

/// The mock's agent UI surface cards (`uiSurfaceScene`): one turn of `UISurfaceFixtures.Scene`'s
/// cards, each on its own tool call as Rust attaches it, and the Mac's answers played locally: an
/// action gets a host-written Pending, a confirm clears it.
extension MockAgentSession {
    func replayUISurfaceTurn(_ name: String) {
        guard let scene = UISurfaceFixtures.Scene(rawValue: name) else { return }
        let at = Date()
        let turnID = "ui-\(name)"
        emit(.userMessage(text: scene.prompt, promptId: "p-\(turnID)", turnId: turnID, attachments: [], at: at))
        emit(.turnStarted(turnId: turnID, at: at))
        for (index, surface) in scene.surfaces.enumerated() {
            let id = "\(turnID)-\(index)"
            var call = ACPToolCall(id: id, title: "mcp__cmux__ui_surface", kind: .other,
                                   status: surface["status"]?.stringValue == "streaming" ? .inProgress : .completed,
                                   content: [.content(.text("Showed a card in the chat."))])
            call.uiSurface = surface
            if let surfaceID = surface["surfaceId"]?.stringValue { uiSurfaceCalls[surfaceID] = (id, surface) }
            emit(.update(.toolCall(call)))
        }
        emit(.turnResult(turnId: turnID, status: .completed, errorText: nil, at: at.addingTimeInterval(2)))
    }

    /// The Mac's answer to a surface intent, played here.
    @discardableResult
    func uiSurfaceReply(_ intent: AgentClientIntent) -> JSONValue? {
        switch intent {
        case .uiSurfaceAction(let surfaceID, let actionID, let values):
            guard let entry = uiSurfaceCalls[surfaceID], let surface = UISurface(json: entry.surface) else { return nil }
            let node = surface.node(withAction: actionID)
            let action = [node?.action, node?.approve, node?.deny, node?.submit].compactMap { $0 }.first { $0.id == actionID }
            let name = action?.name ?? actionID
            let sends = values.sorted { $0.key < $1.key }.map { key, value in
                (label: key.split(separator: "/").last.map { String($0) } ?? key, value: value.uiSurfaceText)
            }
            let list = sends.map { "\($0.label) = \($0.value)" }.joined(separator: ", ")
            let summary = sends.isEmpty ? "Send \"\(name)\" to the agent" : "Send \"\(name)\" to the agent with: \(list)"
            return .object([
                "requestId": .string("r-\(surfaceID)-\(actionID)"), "actionId": .string(actionID), "summary": .string(summary),
                "sends": .array(sends.map { JSONValue.object(["label": .string($0.label), "value": .string($0.value)]) }),
                "target": .string("agent"),
            ])
        case .uiSurfaceConfirm(let surfaceID, _), .uiSurfaceCancel(let surfaceID, _):
            // The request is gone either way: the call's surface carries no pending any more.
            guard let entry = uiSurfaceCalls[surfaceID], case .object(var surface) = entry.surface,
                  let pending = surface["pending"], pending != .null else { return nil }
            surface["pending"] = .null
            uiSurfaceCalls[surfaceID] = (entry.callID, .object(surface))
            emit(.update(.toolCallUpdate(ACPToolCallUpdate(toolCallId: entry.callID, uiSurface: .object(surface)))))
            return nil
        default:
            return nil
        }
    }

    public func uiSurfaceRequest(_ intent: AgentClientIntent) async -> JSONValue? {
        uiSurfaceReply(intent)
    }
}
#endif
