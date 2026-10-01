import CmuxNextControl
import CmuxNextSettings
import Foundation

// Debug verbs for the agent GUI, so a check drives it through the tagged
// app's socket: `debug.agent` reports, the others act on the open conversation.
extension AppControl {
    func registerAgentMethods(_ services: AppServices) {
        guard let router = service?.router else { return }
        let agents = services.agents
        router.register([
            .mainActor("debug.agent") { _ in
                .value(try JSONValue.parse(agents.debugReport()))
            },
            .mainActor("debug.agent.window") { _ in
                agents.showWindow()
                return .value(.object(["ok": .bool(true)]))
            },
            .mainActor("debug.agent.new") { _ in
                agents.debugNew()
                return .value(.object(["ok": .bool(true)]))
            },
            .mainActor("debug.agent.open") { call in
                guard let id = call.params["id"]?.stringValue else { throw ControlError.invalidParams("id is required") }
                agents.debugOpen(id)
                return .value(.object(["ok": .bool(true)]))
            },
            .mainActor("debug.agent.send") { call in
                let text = call.params["text"]?.stringValue ?? ""
                let files = call.params["files"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let steer = call.params["steer"]?.boolValue ?? false
                return .followUp {
                    guard let id = await agents.debugSend(text: text, files: files, steer: steer) else {
                        throw ControlError(code: "unavailable", message: "no open conversation")
                    }
                    return .object(["clientMessageId": .string(id)])
                }
            },
            .mainActor("debug.agent.dequeue") { call in
                guard let id = call.params["clientMessageId"]?.stringValue else { throw ControlError.invalidParams("clientMessageId is required") }
                return .followUp {
                    try await agents.debugDequeue(id)
                    return .object(["ok": .bool(true)])
                }
            },
            .mainActor("debug.agent.retry") { call in
                guard let id = call.params["clientMessageId"]?.stringValue else { throw ControlError.invalidParams("clientMessageId is required") }
                return .followUp {
                    try await agents.debugRetry(id)
                    return .object(["ok": .bool(true)])
                }
            },
            .mainActor("debug.agent.answer") { call in
                guard let request = call.params["requestId"]?.stringValue, let option = call.params["optionId"]?.stringValue else {
                    throw ControlError.invalidParams("requestId and optionId are required")
                }
                return .followUp {
                    try await agents.debugAnswer(request: request, option: option)
                    return .object(["ok": .bool(true)])
                }
            },
            .mainActor("debug.agent.command") { call in
                guard let name = call.params["name"]?.stringValue else { throw ControlError.invalidParams("name is required") }
                return .followUp {
                    try await agents.debugCommand(name)
                    return .object(["ok": .bool(true)])
                }
            },
        ])
    }
}
