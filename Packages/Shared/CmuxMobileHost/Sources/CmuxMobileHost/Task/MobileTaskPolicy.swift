import Foundation
import CmuxMobileWire

/// Default-deny authorization for task ops from a phone (c8-composer.md
/// section 3; the relay rules of skills/cmux-socket-policy).
///
/// - Only `task.dispatch` and `task.cancel`; command-bearing params refused first.
/// - Params outside the schema are refused.
/// - The agent must be one this Mac advertises right now and is not unavailable;
///   model and effort must be ones that agent and model offer. No phone string
///   ever names a binary, flag or harness the Mac did not list.
/// - The prompt is data (no NUL, at most 100000 characters).
/// - Workspace ids must resolve in this host's current tree; attachments are
///   upload ids, never paths.
/// - A dispatch starts an agent process, so it runs only when
///   `allowsDispatch` is set after a live verification on this Mac.
public struct MobileTaskPolicy: Sendable {
    public static let promptLimit = 100_000

    public static let allowedParams: [String: Set<String>] = [
        "task.dispatch": ["host", "workspace", "agent", "model", "effort", "prompt", "attachments", "template"],
        "task.cancel": ["task"],
    ]

    public var hostID: String
    public var allowsDispatch: Bool

    public init(hostID: String, allowsDispatch: Bool = false) {
        self.hostID = hostID
        self.allowsDispatch = allowsDispatch
    }

    public func evaluate(op: String, params: JSONValue, workspaces: MobileWorkspaceState,
                         tasks: MobileTaskStreamState) -> Result<MobileTaskOp, MobileOpRejection> {
        guard let allowed = Self.allowedParams[op] else {
            return .failure(MobileOpPolicy.forbidden("\(op) is not available to a phone"))
        }
        guard let object = params.objectValue else {
            return .failure(MobileOpPolicy.invalid("params must be an object"))
        }
        let commandBearing = Set(object.keys).intersection(MobileOpPolicy.commandParams)
        guard commandBearing.isEmpty else {
            return .failure(MobileOpPolicy.forbidden("\(op) does not take \(commandBearing.sorted().joined(separator: ", ")) from a phone"))
        }
        let extra = Set(object.keys).subtracting(allowed)
        guard extra.isEmpty else {
            return .failure(MobileOpPolicy.invalid("\(op) does not take \(extra.sorted().joined(separator: ", "))"))
        }
        switch op {
        case "task.cancel":
            guard let task = object["task"]?.stringValue, MobileOpPolicy.matches(task, prefix: "task_") else {
                return .failure(MobileOpPolicy.invalid("task.cancel needs a task_ id"))
            }
            guard tasks.task(task) != nil else { return .failure(MobileOpPolicy.notFound("task.not_found", task)) }
            return .success(.cancel(task: task))
        default:
            return dispatch(object, workspaces: workspaces, tasks: tasks)
        }
    }

    private func dispatch(_ object: [String: JSONValue], workspaces: MobileWorkspaceState,
                          tasks: MobileTaskStreamState) -> Result<MobileTaskOp, MobileOpRejection> {
        if let host = object["host"], host.stringValue != hostID {
            return .failure(MobileOpPolicy.invalid("params.host names another host"))
        }
        guard allowsDispatch else {
            return .failure(MobileOpRejection(
                code: "auth.forbidden",
                message: "starting agents from a phone is disabled until it is verified on this Mac",
                details: .object(["reason": .string("spawn_unverified")])))
        }
        guard let agentID = object["agent"]?.stringValue, !agentID.isEmpty else {
            return .failure(MobileOpPolicy.invalid("task.dispatch needs an agent"))
        }
        guard let agent = tasks.agent(agentID) else {
            return .failure(MobileOpRejection(code: "task.agent_unavailable", message: "\(agentID) is not offered by this Mac",
                                              details: .object(["agent": .string(agentID)])))
        }
        if let reason = agent.unavailable {
            return .failure(MobileOpRejection(code: "task.agent_unavailable", message: "\(agent.name): \(reason)",
                                              details: .object(["agent": .string(agentID)])))
        }
        var model: MobileAgentModel?
        if let value = object["model"] {
            guard let id = value.stringValue, let offered = agent.model(id) else {
                return .failure(MobileOpPolicy.invalid("\(agent.name) does not offer model \(value.stringValue ?? "")"))
            }
            model = offered
        }
        var effort: String?
        if let value = object["effort"] {
            let offered = model?.efforts ?? agent.model(agent.defaultModel ?? "")?.efforts ?? []
            guard let step = value.stringValue, offered.contains(step) else {
                return .failure(MobileOpPolicy.invalid("effort \(value.stringValue ?? "") is not offered for this model"))
            }
            effort = step
        }
        guard let prompt = object["prompt"]?.stringValue,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.count <= Self.promptLimit, !prompt.contains("\u{0}") else {
            return .failure(MobileOpPolicy.invalid("prompt must be 1 to \(Self.promptLimit) characters without NUL"))
        }
        var workspace: String?
        if let value = object["workspace"] {
            guard let id = value.stringValue, MobileOpPolicy.matches(id, prefix: "ws_") else {
                return .failure(MobileOpPolicy.invalid("workspace must be a ws_ id"))
            }
            guard workspaces.workspace(id) != nil else { return .failure(MobileOpPolicy.notFound("workspace.not_found", id)) }
            workspace = id
        }
        var uploads: [String] = []
        if let value = object["attachments"] {
            guard case .array(let items) = value, items.count <= 32 else {
                return .failure(MobileOpPolicy.invalid("attachments must be at most 32 upload ids"))
            }
            for item in items {
                guard let id = item.stringValue, MobileOpPolicy.matches(id, prefix: "up_") else {
                    return .failure(MobileOpPolicy.invalid("attachments take up_ upload ids only"))
                }
                uploads.append(id)
            }
        }
        var template: String?
        if let value = object["template"] {
            guard let label = value.stringValue, (1...128).contains(label.count),
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) }) else {
                return .failure(MobileOpPolicy.invalid("template must be a label of [A-Za-z0-9._:-]"))
            }
            template = label
        }
        return .success(.dispatch(MobileTaskDispatch(agent: agent.id, model: model?.id, effort: effort, prompt: prompt,
                                                     workspace: workspace, uploads: uploads, template: template)))
    }
}
