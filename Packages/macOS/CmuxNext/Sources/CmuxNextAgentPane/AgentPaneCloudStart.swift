public import Foundation

/// `cloud.startChat {task, cwd, harness?, model?, key}`: a new chat's first send with Cloud picked
/// as where it runs (the environment picker's Cloud row, Labs). The App picks or makes a Cloud
/// machine sized for the chat, copies the chat's folder there, starts the chat there with this
/// prompt and shows it, with no machine, size or environment prompt (``AgentPaneModel/onCloudStartChat``).
public nonisolated struct AgentPaneCloudStart: Sendable, Equatable {
    /// The person's first prompt (never logged).
    public var task: String
    /// The chat's folder on this Mac, absolute.
    public var cwd: String
    public var harness: String?
    public var model: String?
    /// The page's send: a second call with the same key while one runs is the same send.
    public var key: String

    public init(task: String, cwd: String, harness: String? = nil, model: String? = nil, key: String) {
        (self.task, self.cwd, self.harness, self.model, self.key) = (task, cwd, harness, model, key)
    }

    /// The page's params, checked; nil for anything else.
    public init?(params: [String: Any]?) {
        let name = { (key: String) -> String?? in
            guard let value = params?[key] else { return .some(nil) }
            guard let text = value as? String, !text.isEmpty, text.count <= 128 else { return nil }
            return .some(text)
        }
        guard let task = params?["task"] as? String, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              task.count <= AgentPaneRequest.maximumSandboxTask,
              let cwd = params?["cwd"] as? String, cwd.hasPrefix("/"), !cwd.contains("\0"), cwd.count <= 4096,
              let key = params?["key"] as? String, UUID(uuidString: key) != nil,
              let harness = name("harness"), let model = name("model") else { return nil }
        self.init(task: task, cwd: cwd, harness: harness, model: model, key: key)
    }
}

/// A new chat's first send that runs somewhere other than this Mac's chat: a Sandboxed send
/// (`sandbox.run`) or a Cloud chat (`cloud.startChat`). Both are the Send's own gesture, only for a
/// chat that has not started or opened here, one at a time, and while one runs no chat starts or
/// opens here. The send line drains first, so a start or open the page handed over before is counted.
@MainActor
struct AgentPaneHandOff {
    let model: AgentPaneModel

    func sandbox(task: String, agent: String?, key: String) async -> [String: Any] {
        guard let run = model.onSandboxRun else { return AgentPaneModel.unsupported("sandbox.run") }
        return await held("sandbox.run") { replacements in
            await model.sandboxRuns.run(task: task, key: key) {
                defer { replacements.endSandbox() }
                return await run(task, agent, key)
            }
        }
    }

    func cloud(_ start: AgentPaneCloudStart) async -> [String: Any] {
        guard let run = model.onCloudStartChat else { return AgentPaneModel.unsupported("cloud.startChat") }
        return await held("cloud.startChat") { replacements in
            defer { replacements.endSandbox() }
            return await run(start)
        }
    }

    /// The shared guards, then `body` with the replacements held (it ends the hold).
    private func held(_ method: String, _ body: (AcpmuxPaneReplacements) async -> [String: Any]) async -> [String: Any] {
        guard model.sessionId == nil else { return AgentPaneModel.unsupported(method) }
        let notNow = AgentPaneReply.failure(code: "unavailable_now", message: "unavailable_now")
        let transport = model.transport
        guard await transport.lineDrained(within: .seconds(5)) else { return notNow }
        if let refusal = model.sandboxRuns.refusal { return AgentPaneReply.failure(code: refusal, message: refusal) }
        let replacements = transport.replacements
        guard replacements.beginSandbox() else { return notNow }
        guard transport.gestures.consume() else {
            replacements.endSandbox()
            return AgentPaneModel.transportFailure(.gestureRequired)
        }
        return await body(replacements)
    }
}
