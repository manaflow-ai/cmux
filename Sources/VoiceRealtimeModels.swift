import Foundation

enum VoiceConnectionState: Equatable {
    case disconnected
    case preparing
    case connecting
    case connected
    case failed(String)

    var localizedTitle: String {
        switch self {
        case .disconnected:
            return String(localized: "voice.state.disconnected", defaultValue: "Disconnected")
        case .preparing:
            return String(localized: "voice.state.preparing", defaultValue: "Preparing")
        case .connecting:
            return String(localized: "voice.state.connecting", defaultValue: "Connecting")
        case .connected:
            return String(localized: "voice.state.connected", defaultValue: "Connected")
        case .failed:
            return String(localized: "voice.state.failed", defaultValue: "Failed")
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .connecting, .connected:
            return true
        case .disconnected, .failed:
            return false
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

enum VoiceTranscriptRole: String {
    case user
    case assistant
    case tool
    case system
    case error

    var localizedLabel: String {
        switch self {
        case .user:
            return String(localized: "voice.role.user", defaultValue: "You")
        case .assistant:
            return String(localized: "voice.role.assistant", defaultValue: "Voice")
        case .tool:
            return String(localized: "voice.role.tool", defaultValue: "Tool")
        case .system:
            return String(localized: "voice.role.system", defaultValue: "System")
        case .error:
            return String(localized: "voice.role.error", defaultValue: "Error")
        }
    }

    var symbolName: String {
        switch self {
        case .user:
            return "person.fill"
        case .assistant:
            return "waveform"
        case .tool:
            return "wrench.and.screwdriver"
        case .system:
            return "info.circle"
        case .error:
            return "exclamationmark.triangle"
        }
    }
}

struct VoiceTranscriptItem: Identifiable, Equatable {
    let id: UUID
    let role: VoiceTranscriptRole
    var text: String
    let date: Date

    init(id: UUID = UUID(), role: VoiceTranscriptRole, text: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}

struct VoiceRealtimeFunctionCall: Equatable {
    let callID: String
    let name: String
    let arguments: String
}

struct VoiceRealtimeTextDelta: Equatable {
    let itemID: String
    let text: String
}

enum VoiceJSON {
    enum Error: Swift.Error, LocalizedError {
        case invalidJSONObject
        case invalidUTF8

        var errorDescription: String? {
            switch self {
            case .invalidJSONObject:
                return String(localized: "voice.error.invalidJSON", defaultValue: "Invalid JSON payload.")
            case .invalidUTF8:
                return String(localized: "voice.error.invalidUTF8", defaultValue: "Invalid UTF-8 payload.")
            }
        }
    }

    static func data(from object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw Error.invalidJSONObject
        }
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func prettyData(from object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw Error.invalidJSONObject
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    static func string(from object: Any) throws -> String {
        let data = try data(from: object)
        guard let value = String(data: data, encoding: .utf8) else {
            throw Error.invalidUTF8
        }
        return value
    }

    static func prettyString(from object: Any) throws -> String {
        let data = try prettyData(from: object)
        guard let value = String(data: data, encoding: .utf8) else {
            throw Error.invalidUTF8
        }
        return value
    }

    static func dictionary(fromJSONString string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    static func parseArguments(_ string: String) -> [String: Any] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        return dictionary(fromJSONString: trimmed) ?? [:]
    }
}

enum VoiceRealtimeEventParser {
    static func eventType(in event: [String: Any]) -> String? {
        event["type"] as? String
    }

    static func assistantDelta(in event: [String: Any]) -> String? {
        switch eventType(in: event) {
        case "response.output_audio_transcript.delta", "response.output_text.delta":
            return nonEmptyString(event["delta"])
        default:
            return nil
        }
    }

    static func completedAssistantText(in event: [String: Any]) -> String? {
        switch eventType(in: event) {
        case "response.output_audio_transcript.done":
            return nonEmptyString(event["transcript"])
        case "response.output_text.done":
            return nonEmptyString(event["text"])
        default:
            return nil
        }
    }

    static func completedUserText(in event: [String: Any]) -> String? {
        if let completed = completedUserTranscription(in: event) {
            return completed.text
        }

        guard eventType(in: event) == "conversation.item.done",
              let item = event["item"] as? [String: Any],
              item["role"] as? String == "user",
              let content = item["content"] as? [[String: Any]] else {
            return nil
        }

        for part in content {
            if let text = nonEmptyString(part["text"]) ?? nonEmptyString(part["transcript"]) {
                return text
            }
        }
        return nil
    }

    static func userTranscriptionDelta(in event: [String: Any]) -> VoiceRealtimeTextDelta? {
        guard eventType(in: event) == "conversation.item.input_audio_transcription.delta",
              let itemID = nonEmptyString(event["item_id"]),
              let delta = nonEmptyString(event["delta"]) else {
            return nil
        }
        return VoiceRealtimeTextDelta(itemID: itemID, text: delta)
    }

    static func completedUserTranscription(in event: [String: Any]) -> VoiceRealtimeTextDelta? {
        guard eventType(in: event) == "conversation.item.input_audio_transcription.completed",
              let itemID = nonEmptyString(event["item_id"]),
              let transcript = nonEmptyString(event["transcript"]) else {
            return nil
        }
        return VoiceRealtimeTextDelta(itemID: itemID, text: transcript)
    }

    static func speechStartedItemID(in event: [String: Any]) -> String? {
        guard eventType(in: event) == "input_audio_buffer.speech_started" else {
            return nil
        }
        return nonEmptyString(event["item_id"])
    }

    static func isActiveResponseError(in event: [String: Any]) -> Bool {
        guard eventType(in: event) == "error" else { return false }
        let code = errorCode(in: event)?.lowercased() ?? ""
        let message = errorMessage(in: event)?.lowercased() ?? ""
        return code.contains("conversation_already_has_active_response")
            || code.contains("active_response")
            || message.contains("active response")
    }

    static func errorCode(in event: [String: Any]) -> String? {
        if let error = event["error"] as? [String: Any] {
            return nonEmptyString(error["code"])
        }
        return nonEmptyString(event["code"])
    }

    static func errorMessage(in event: [String: Any]) -> String? {
        if let error = event["error"] as? [String: Any] {
            return nonEmptyString(error["message"]) ?? nonEmptyString(error["code"])
        }
        if eventType(in: event) == "error" {
            return nonEmptyString(event["message"]) ?? String(localized: "voice.error.realtime", defaultValue: "Realtime session error.")
        }
        if let type = eventType(in: event), type.hasSuffix("_error") {
            return nonEmptyString(event["message"]) ?? type
        }
        return nil
    }

    static func functionCalls(in event: [String: Any]) -> [VoiceRealtimeFunctionCall] {
        var calls: [VoiceRealtimeFunctionCall] = []

        if let item = event["item"] as? [String: Any],
           let call = functionCall(from: item) {
            calls.append(call)
        }

        if let response = event["response"] as? [String: Any],
           let output = response["output"] as? [[String: Any]] {
            for item in output {
                if let call = functionCall(from: item) {
                    calls.append(call)
                }
            }
        }

        return calls
    }

    private static func functionCall(from item: [String: Any]) -> VoiceRealtimeFunctionCall? {
        guard item["type"] as? String == "function_call",
              let name = nonEmptyString(item["name"]),
              let callID = nonEmptyString(item["call_id"]) else {
            return nil
        }
        return VoiceRealtimeFunctionCall(
            callID: callID,
            name: name,
            arguments: (item["arguments"] as? String) ?? "{}"
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : string
    }
}
