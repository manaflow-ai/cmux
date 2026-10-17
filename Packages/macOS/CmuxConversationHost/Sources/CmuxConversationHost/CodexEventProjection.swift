import Foundation
import CmuxConversation

/// Projects exact app-server notification names. Full item completions replace accumulated deltas.
struct CodexEventProjection: Sendable {
    private var text: [String: String] = [:]
    private var tools: [String: ConversationTool] = [:]
    private(set) var completedTurns: Set<String> = []
    private var completedOrder: [String] = []

    mutating func events(method: String, params: [String: ConversationJSONValue], raw: ConversationJSONValue) -> [ConversationProviderEvent] {
        let turn = params["turnId"]?.stringValue.map(ConversationTurnID.init(rawValue:))
        let item = params["itemId"]?.stringValue.map(ConversationItemID.init(rawValue:))
        switch method {
        case "turn/started", "turn/completed":
            let value = params["turn"]?.objectValue ?? [:]
            let id = value["id"]?.stringValue ?? turn?.rawValue
            let state: String
            if method == "turn/started" { state = "running" }
            else {
                switch value["status"]?.stringValue { case "interrupted": state = "cancelled"; case "failed": state = "failed"; default: state = "completed" }
                if let id, completedTurns.insert(id).inserted {
                    completedOrder.append(id)
                    if completedOrder.count > 64 { completedTurns.remove(completedOrder.removeFirst()) }
                }
                // Deltas need only the active turn. The durable journal owns completed items.
                text.removeAll(); tools.removeAll()
            }
            return [.init(kind: .turn, turnID: id.map(ConversationTurnID.init(rawValue:)), state: state, rawPayload: raw)]
        case "item/agentMessage/delta", "item/reasoning/summaryTextDelta", "item/plan/delta":
            guard let item, let delta = params["delta"]?.stringValue else { return [unknown(method, raw)] }
            let kind: ConversationItemKind = method.contains("reasoning") ? .reasoning : (method.contains("plan") ? .plan : .message)
            let accumulated = (text[item.rawValue] ?? "") + delta
            // A malformed runaway delta is explicit; never silently truncate text.
            guard accumulated.utf8.count <= 4 * 1_024 * 1_024 else { return [.init(kind: .item, itemID: item, turnID: turn, itemKind: .error, text: "Provider text exceeds the display limit", rawPayload: raw)] }
            text[item.rawValue] = accumulated
            return [.init(kind: .item, itemID: item, turnID: turn, itemKind: kind, itemUpdate: .appendText, role: "assistant", text: delta, plan: kind == .plan ? .init(text: delta) : nil, rawPayload: raw)]
        case "item/commandExecution/outputDelta":
            guard let item, let delta = params["delta"]?.stringValue else { return [unknown(method, raw)] }
            var tool = tools[item.rawValue] ?? .init(toolID: item.rawValue, name: "Command", status: .running)
            let output = (tool.output?.stringValue ?? "") + delta
            guard output.utf8.count <= 4 * 1_024 * 1_024 else { return [.init(kind: .item, itemID: item, turnID: turn, itemKind: .error, text: "Tool output exceeds the display limit", rawPayload: raw)] }
            tool.output = .string(output); tools[item.rawValue] = tool
            tool.output = .string(delta)
            return [.init(kind: .item, itemID: item, turnID: turn, itemKind: .tool, itemUpdate: .appendToolOutput, tool: tool, rawPayload: raw)]
        case "item/started", "item/completed":
            guard let value = params["item"]?.objectValue else { return [unknown(method, raw)] }
            return itemEvents(value, turn: turn, raw: raw)
        case "turn/plan/updated":
            let steps = (params["plan"]?.arrayValue ?? []).compactMap { value -> String? in
                guard let item = value.objectValue, let step = item["step"]?.stringValue else { return nil }
                return "\(item["status"]?.stringValue == "completed" ? "✓" : "•") \(step)"
            }.joined(separator: "\n")
            let plan = [params["explanation"]?.stringValue, steps.isEmpty ? nil : steps].compactMap { $0 }.joined(separator: "\n\n")
            return [.init(kind: .item, itemID: .init(rawValue: "plan:\(turn?.rawValue ?? "current")"), turnID: turn, itemKind: .plan, plan: .init(text: plan), rawPayload: raw)]
        case "turn/diff/updated":
            return [.init(kind: .item, itemID: .init(rawValue: "diff:\(turn?.rawValue ?? "current")"), turnID: turn, itemKind: .files, diff: .init(path: "", text: params["diff"]?.stringValue ?? "", comparison: "last-turn"), rawPayload: raw)]
        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"]?.objectValue?["last"]?.objectValue ?? params["tokenUsage"]?.objectValue?["total"]?.objectValue ?? [:]
            return [.init(kind: .item, itemID: .init(rawValue: "usage:\(turn?.rawValue ?? "current")"), turnID: turn, itemKind: .usage, usage: .init(inputTokens: int(usage["inputTokens"]), outputTokens: int(usage["outputTokens"]), cachedTokens: int(usage["cachedInputTokens"])), rawPayload: raw)]
        case "error":
            // Native details remain in the raw inspector; the banner does not expose arbitrary stderr.
            return [.init(kind: .item, turnID: turn, itemKind: .error, text: "The provider reported an error", rawPayload: raw)]
        default: return [unknown(method, raw)]
        }
    }

    private mutating func itemEvents(_ value: [String: ConversationJSONValue], turn: ConversationTurnID?, raw: ConversationJSONValue) -> [ConversationProviderEvent] {
        guard let nativeID = value["id"]?.stringValue, let type = value["type"]?.stringValue else { return [unknown("item", raw)] }
        let id = ConversationItemID(rawValue: nativeID)
        switch type {
        case "userMessage":
            let content = (value["content"]?.arrayValue ?? []).compactMap { $0.objectValue?["text"]?.stringValue }.joined(separator: "\n")
            return [.init(kind: .item, itemID: id, turnID: turn, itemKind: .message, role: "user", text: content, rawPayload: raw)]
        case "agentMessage", "plan":
            let content = value["text"]?.stringValue ?? ""
            text[nativeID] = content
            return [.init(kind: .item, itemID: id, turnID: turn, itemKind: type == "plan" ? .plan : .message, role: "assistant", text: content, plan: type == "plan" ? .init(text: content) : nil, rawPayload: raw)]
        case "reasoning":
            let content = (value["summary"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n")
            text[nativeID] = content
            return [.init(kind: .item, itemID: id, turnID: turn, itemKind: .reasoning, text: content, rawPayload: raw)]
        case "commandExecution":
            let tool = ConversationTool(toolID: nativeID, name: "Command", input: value["command"], output: value["aggregatedOutput"], status: status(value["status"]?.stringValue))
            tools[nativeID] = tool
            return [.init(kind: .item, itemID: id, turnID: turn, itemKind: .tool, tool: tool, rawPayload: raw)]
        case "mcpToolCall", "dynamicToolCall":
            let tool = ConversationTool(toolID: nativeID, name: value["tool"]?.stringValue ?? type, input: value["arguments"], output: value["result"] ?? value["contentItems"] ?? value["error"], status: status(value["status"]?.stringValue))
            tools[nativeID] = tool
            return [.init(kind: .item, itemID: id, turnID: turn, itemKind: .tool, tool: tool, rawPayload: raw)]
        case "collabAgentToolCall", "subAgentActivity":
            let label = value["tool"]?.stringValue ?? value["agentPath"]?.stringValue ?? type
            return [.init(kind: .item, itemID: id, turnID: turn, itemKind: .child, text: label, tool: .init(toolID: nativeID, name: label, input: value["prompt"], output: value["agentsStates"] ?? value["agentThreadId"], status: status(value["status"]?.stringValue)), rawPayload: raw)]
        case "fileChange":
            return (value["changes"]?.arrayValue ?? []).enumerated().compactMap { index, change in
                guard let change = change.objectValue else { return nil }
                return .init(kind: .item, itemID: .init(rawValue: "\(nativeID):\(index)"), turnID: turn, itemKind: .files, diff: .init(path: change["path"]?.stringValue ?? "", text: change["diff"]?.stringValue ?? "", comparison: "last-turn"), rawPayload: raw)
            }
        case "imageView", "imageGeneration":
            guard let path = value["savedPath"]?.stringValue ?? value["path"]?.stringValue, path.hasPrefix("/") else { return [unknown(type, raw)] }
            let url = URL(fileURLWithPath: path)
            return [.init(kind: .item, itemID: id, turnID: turn, itemKind: .artifact, artifact: .init(artifactID: nativeID, fileName: url.lastPathComponent, mediaType: ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? "image/jpeg" : "image/png", remoteURL: url.absoluteString), rawPayload: raw)]
        case "functionCallOutput":
            return [.init(kind: .item, itemID: id, turnID: turn, itemKind: .result, text: value["output"]?.stringValue, tool: .init(toolID: nativeID, name: value["name"]?.stringValue ?? "Result", output: value["output"], status: .success), rawPayload: raw)]
        default: return [.init(kind: .item, itemID: id, turnID: turn, itemKind: .unknown(type), rawPayload: raw)]
        }
    }

    private func status(_ value: String?) -> ConversationToolStatus {
        switch value { case "completed": .success; case "failed", "errored", "declined": .failed; case "interrupted": .cancelled; case "inProgress", "running": .running; default: .unknown }
    }
    private func int(_ value: ConversationJSONValue?) -> Int64? { value?.numberValue.flatMap(Int64.init) }
    private func unknown(_ method: String, _ raw: ConversationJSONValue) -> ConversationProviderEvent { .init(kind: .unknown(method), rawPayload: raw) }
}
