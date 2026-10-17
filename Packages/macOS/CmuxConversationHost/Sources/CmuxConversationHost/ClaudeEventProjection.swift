import Foundation
import CmuxConversation

/// Projects nested Anthropic stream events and complete content blocks using native IDs.
struct ClaudeEventProjection: Sendable {
    private struct Block: Sendable {
        var value: [String: ConversationJSONValue]
        var inputJSON = ""
        var complete = false
    }
    private var currentMessages: [String: String] = [:]
    private var blocks: [String: [Int: Block]] = [:]
    private var tools: [String: ConversationTool] = [:]
    private var completedEnvelopes: Set<String> = []

    mutating func events(_ raw: ConversationJSONValue, turnID: ConversationTurnID?) throws -> [ConversationProviderEvent] {
        guard let value = raw.objectValue, let type = value["type"]?.stringValue else { return [] }
        let parent = value["parent_tool_use_id"]?.stringValue
        let lane = parent ?? "main"
        switch type {
        case "stream_event":
            guard let event = value["event"]?.objectValue else { return [unknown(type, raw)] }
            let eventType = event["type"]?.stringValue ?? "unknown"
            if eventType == "message_start", let message = event["message"]?.objectValue, let id = message["id"]?.stringValue {
                currentMessages[lane] = id
                return []
            }
            guard let messageID = currentMessages[lane] else { return [unknown(eventType, raw)] }
            guard let index = event["index"]?.numberValue.flatMap(Int.init) else {
                if eventType == "message_delta", let usage = event["usage"]?.objectValue { return [usageEvent(usage, id: messageID, turn: turnID, raw: raw)] }
                return []
            }
            if eventType == "content_block_start", let block = event["content_block"]?.objectValue {
                blocks[messageID, default: [:]][index] = Block(value: block)
            } else if eventType == "content_block_delta", let delta = event["delta"]?.objectValue, var block = blocks[messageID]?[index] {
                switch delta["type"]?.stringValue {
                case "text_delta": try append(delta["text"]?.stringValue ?? "", field: "text", to: &block)
                case "thinking_delta": try append(delta["thinking"]?.stringValue ?? "", field: "thinking", to: &block)
                case "input_json_delta":
                    block.inputJSON += delta["partial_json"]?.stringValue ?? ""
                    guard block.inputJSON.utf8.count <= 1_048_576 else { throw ConversationProviderError.malformed("Claude tool input exceeded the display limit") }
                    if let data = block.inputJSON.data(using: .utf8), let input = try? JSONDecoder().decode(ConversationJSONValue.self, from: data) { block.value["input"] = input }
                default: return []
                }
                blocks[messageID]?[index] = block
                if delta["type"]?.stringValue == "text_delta" || delta["type"]?.stringValue == "thinking_delta" {
                    let thinking = delta["type"]?.stringValue == "thinking_delta"
                    return [.init(kind: .item, itemID: .init(rawValue: messageID + ":" + String(index)), turnID: turnID, itemKind: thinking ? .reasoning : (parent == nil ? .message : .child), itemUpdate: .appendText, role: thinking ? nil : "assistant", text: delta[thinking ? "thinking" : "text"]?.stringValue ?? "", rawPayload: raw)]
                }
            } else if eventType != "content_block_stop" { return [] }
            guard let block = blocks[messageID]?[index] else { return [] }
            return project(block.value, id: messageID + ":" + String(index), turn: turnID, parent: parent, raw: raw)
        case "assistant":
            if let uuid = value["uuid"]?.stringValue {
                guard completedEnvelopes.insert(uuid).inserted else { return [] }
            }
            guard let message = value["message"]?.objectValue, let id = message["id"]?.stringValue else { return [unknown(type, raw)] }
            let content = message["content"]?.arrayValue ?? []
            var result: [ConversationProviderEvent] = []
            for (position, content) in content.enumerated() {
                guard let block = content.objectValue else { continue }
                // Claude may emit a single completed block per envelope while
                // retaining one message ID. Match the outstanding stream block.
                let index: Int
                if contentCount(message) == 1,
                   let existing = blocks[id]?.keys.sorted().first(where: { key in
                       guard let existing = blocks[id]?[key] else { return false }
                       return !existing.complete && existing.value["type"] == block["type"]
                           && (block["id"] == nil || existing.value["id"] == block["id"])
                   }) { index = existing }
                else if contentCount(message) == 1, let last = blocks[id]?.keys.max() { index = last + 1 }
                else { index = position }
                blocks[id, default: [:]][index] = Block(value: block, complete: true)
                result += project(block, id: id + ":" + String(index), turn: turnID, parent: parent, raw: raw)
            }
            if let usage = message["usage"]?.objectValue { result.append(usageEvent(usage, id: id, turn: turnID, raw: raw)) }
            try checkBounds()
            return result
        case "user":
            guard let message = value["message"]?.objectValue else { return [unknown(type, raw)] }
            let id = value["uuid"]?.stringValue ?? value["user_message_uuid"]?.stringValue
            if let text = message["content"]?.stringValue, let id {
                return [.init(kind: .item, itemID: .init(rawValue: "user:" + id), turnID: turnID, itemKind: parent == nil ? .message : .child, role: "user", text: text, rawPayload: raw)]
            }
            var result: [ConversationProviderEvent] = []
            for (index, block) in (message["content"]?.arrayValue ?? []).enumerated() {
                guard let block = block.objectValue else { continue }
                if block["type"]?.stringValue == "tool_result", let toolID = block["tool_use_id"]?.stringValue {
                    var tool = tools[toolID] ?? .init(toolID: toolID, name: "Tool", status: .unknown)
                    let detached = value["tool_use_result"]?.objectValue?["detachedToolCall"]?.boolValue == true
                    tool.status = detached ? .running : (block["is_error"]?.boolValue == true ? .failed : .success)
                    tool.output = value["tool_use_result"] ?? block["content"]
                    tools[toolID] = tool
                    result.append(.init(kind: .item, itemID: .init(rawValue: toolID), turnID: turnID, itemKind: .tool, tool: tool, rawPayload: raw))
                } else if block["type"]?.stringValue == "text", let id {
                    result.append(.init(kind: .item, itemID: .init(rawValue: "user:" + id + ":" + String(index)), turnID: turnID, itemKind: parent == nil ? .message : .child, role: "user", text: block["text"]?.stringValue, rawPayload: raw))
                } else { result.append(unknown(block["type"]?.stringValue ?? "user-content", raw)) }
            }
            return result
        case "result":
            let id = value["uuid"]?.stringValue ?? turnID?.rawValue ?? "result"
            var result: [ConversationProviderEvent] = []
            if let usage = value["usage"]?.objectValue { result.append(usageEvent(usage, id: id, turn: turnID, raw: raw)) }
            if value["is_error"]?.boolValue == true { result.append(.init(kind: .item, itemID: .init(rawValue: "error:" + id), turnID: turnID, itemKind: .error, text: (value["errors"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n"), rawPayload: raw)) }
            // Tools remain as last reported; stopping a turn does not complete live tools.
            currentMessages.removeAll(); blocks.removeAll(); completedEnvelopes.removeAll()
            return result
        case "system":
            let subtype = value["subtype"]?.stringValue ?? "unknown"
            if subtype.hasPrefix("task_"), let id = value["task_id"]?.stringValue {
                return [.init(kind: .item, itemID: .init(rawValue: "child:" + id), turnID: turnID, itemKind: .child, text: value["description"]?.stringValue ?? value["summary"]?.stringValue ?? subtype, rawPayload: raw)]
            }
            return [unknown("system." + subtype, raw)]
        default: return [unknown(type, raw)]
        }
    }

    private func contentCount(_ message: [String: ConversationJSONValue]) -> Int { message["content"]?.arrayValue?.count ?? 0 }
    private mutating func append(_ delta: String, field: String, to block: inout Block) throws {
        let text = (block.value[field]?.stringValue ?? "") + delta
        guard text.utf8.count <= 1_048_576 else { throw ConversationProviderError.malformed("Claude text exceeded the display limit") }
        block.value[field] = .string(text)
    }
    private mutating func project(_ block: [String: ConversationJSONValue], id: String, turn: ConversationTurnID?, parent: String?, raw: ConversationJSONValue) -> [ConversationProviderEvent] {
        switch block["type"]?.stringValue {
        case "text": return [.init(kind: .item, itemID: .init(rawValue: id), turnID: turn, itemKind: parent == nil ? .message : .child, role: "assistant", text: block["text"]?.stringValue, rawPayload: raw)]
        case "thinking": return [.init(kind: .item, itemID: .init(rawValue: id), turnID: turn, itemKind: .reasoning, text: block["thinking"]?.stringValue, rawPayload: raw)]
        case "tool_use", "server_tool_use":
            guard let toolID = block["id"]?.stringValue else { return [unknown("tool-use", raw)] }
            let tool = ConversationTool(toolID: toolID, name: block["name"]?.stringValue ?? "Tool", input: block["input"], status: tools[toolID]?.status ?? .running)
            tools[toolID] = tool
            return [.init(kind: .item, itemID: .init(rawValue: toolID), turnID: turn, itemKind: .tool, tool: tool, rawPayload: raw)]
        default: return [.init(kind: .item, itemID: .init(rawValue: id), turnID: turn, itemKind: .unknown(block["type"]?.stringValue ?? "content"), rawPayload: raw)]
        }
    }
    private func usageEvent(_ usage: [String: ConversationJSONValue], id: String, turn: ConversationTurnID?, raw: ConversationJSONValue) -> ConversationProviderEvent {
        .init(kind: .item, itemID: .init(rawValue: "usage:" + id), turnID: turn, itemKind: .usage, usage: .init(inputTokens: usage["input_tokens"]?.numberValue.flatMap(Int64.init), outputTokens: usage["output_tokens"]?.numberValue.flatMap(Int64.init), cachedTokens: usage["cache_read_input_tokens"]?.numberValue.flatMap(Int64.init)), rawPayload: raw)
    }
    private func checkBounds() throws {
        guard blocks.count <= 1_024, tools.count <= 4_096, completedEnvelopes.count <= 4_096 else { throw ConversationProviderError.unavailable("Claude projection buffer overflow") }
    }
    private func unknown(_ kind: String, _ raw: ConversationJSONValue) -> ConversationProviderEvent { .init(kind: .unknown(kind), rawPayload: raw) }
}
