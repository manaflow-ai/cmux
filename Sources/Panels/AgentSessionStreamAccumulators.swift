import Foundation

struct OpenCodeServerAuth: Equatable {
    let authorizationHeader: String

    init?(environment: [String: String]) {
        guard let password = environment["OPENCODE_SERVER_PASSWORD"],
              !password.isEmpty else {
            return nil
        }
        let username = environment["OPENCODE_SERVER_USERNAME"].flatMap { value -> String? in
            value.isEmpty ? nil : value
        } ?? "opencode"
        let token = "\(username):\(password)"
        authorizationHeader = "Basic \(Data(token.utf8).base64EncodedString())"
    }
}

struct ClaudeStreamJSONAccumulator {
    private var emittedTextByMessageID: [String: String] = [:]
    private var currentMessageID: String?
    private var pendingDeltaText = ""
    private var emittedAnyAssistantText = false

    mutating func consumeLine(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let messageID = assistantMessageID(fromMessageStart: object) {
            currentMessageID = messageID
            pendingDeltaText = ""
            return []
        }

        if let delta = assistantTextDelta(from: object), !delta.isEmpty {
            emittedAnyAssistantText = true
            if let currentMessageID {
                emittedTextByMessageID[currentMessageID, default: ""] += delta
            } else {
                pendingDeltaText += delta
            }
            return [delta]
        }

        if !emittedAnyAssistantText,
           object["type"] as? String == "result",
           let result = object["result"] as? String,
           !result.isEmpty {
            emittedAnyAssistantText = true
            return [result]
        }

        return []
    }

    static func completesAssistantTurn(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return false
        }

        switch type {
        case "result", "message_stop", "done":
            return true
        default:
            return false
        }
    }

    private func assistantMessageID(fromMessageStart object: [String: Any]) -> String? {
        guard object["type"] as? String == "message_start",
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let messageID = message["id"] as? String,
              !messageID.isEmpty else {
            return nil
        }
        return messageID
    }

    private mutating func assistantTextDelta(from object: [String: Any]) -> String? {
        if object["type"] as? String == "content_block_delta",
           let delta = object["delta"] as? [String: Any],
           let text = delta["text"] as? String {
            return text
        }

        guard object["type"] as? String == "assistant" else {
            return nil
        }
        let message = (object["message"] as? [String: Any]) ?? object
        let fullText = Self.contentText(from: message["content"])
        guard !fullText.isEmpty else { return nil }

        let messageID = (message["id"] as? String) ?? "assistant"
        let previousText = emittedTextByMessageID[messageID] ??
            (fullText.hasPrefix(pendingDeltaText) ? pendingDeltaText : "")
        emittedTextByMessageID[messageID] = fullText
        if currentMessageID == messageID {
            currentMessageID = nil
        }
        pendingDeltaText = ""
        if fullText.hasPrefix(previousText) {
            return String(fullText.dropFirst(previousText.count))
        }
        return fullText
    }

    private static func contentText(from content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        if let part = content as? [String: Any] {
            if let type = part["type"] as? String,
               type != "text" {
                return ""
            }
            return part["text"] as? String ?? ""
        }
        if let parts = content as? [Any] {
            return parts.map(contentText(from:)).joined()
        }
        return ""
    }
}

struct OpenCodeEventStreamParser {
    private var dataLines: [String] = []

    mutating func consumeLine(_ line: String) -> [[String: Any]] {
        let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard !line.isEmpty else {
            return flush()
        }
        guard line.hasPrefix("data:") else {
            return []
        }

        var data = String(line.dropFirst("data:".count))
        if data.hasPrefix(" ") {
            data.removeFirst()
        }
        dataLines.append(data)
        return []
    }

    mutating func flush() -> [[String: Any]] {
        guard !dataLines.isEmpty else { return [] }
        let data = dataLines.joined(separator: "\n")
        dataLines.removeAll()
        guard let payload = data.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return []
        }
        return [object]
    }
}

struct OpenCodeEventTextAccumulator {
    private var messageRoleByID: [String: String] = [:]
    private var messageIDByPartID: [String: String] = [:]
    private var isTextPartByID: [String: Bool] = [:]
    private var textByPartID: [String: String] = [:]
    private var emittedCharacterCountByPartID: [String: Int] = [:]

    mutating func consumeEvent(_ event: [String: Any], sessionID: String) -> [String] {
        guard let type = event["type"] as? String,
              let properties = event["properties"] as? [String: Any],
              Self.eventSessionID(properties) == sessionID else {
            return []
        }

        switch type {
        case "message.updated":
            return consumeMessageUpdated(properties)
        case "message.part.updated":
            return consumePartUpdated(properties)
        case "message.part.delta":
            return consumePartDelta(properties)
        default:
            return []
        }
    }

    static func completesAssistantTurn(_ event: [String: Any], sessionID: String) -> Bool {
        guard let type = event["type"] as? String,
              let properties = event["properties"] as? [String: Any],
              eventSessionID(properties) == sessionID else {
            return false
        }

        switch type {
        case "session.idle":
            return true
        case "session.status":
            return sessionStatusIsIdle(properties["status"])
        case "message.updated":
            let info = (properties["info"] as? [String: Any])
                ?? (properties["message"] as? [String: Any])
                ?? [:]
            guard firstString(info["role"], properties["role"]) == "assistant" else {
                return false
            }
            return messageInfoHasCompletedTime(info) ||
                firstString(info["finish"], info["finishedReason"], properties["finish"]) != nil ||
                info["error"] != nil
        default:
            return false
        }
    }

    private static func eventSessionID(_ properties: [String: Any]) -> String? {
        firstString(
            properties["sessionID"],
            properties["sessionId"],
            properties["session_id"],
            nestedString(properties, "info", "sessionID"),
            nestedString(properties, "info", "sessionId"),
            nestedString(properties, "info", "session_id"),
            nestedString(properties, "message", "sessionID"),
            nestedString(properties, "message", "sessionId"),
            nestedString(properties, "message", "session_id"),
            nestedString(properties, "part", "sessionID"),
            nestedString(properties, "part", "sessionId"),
            nestedString(properties, "part", "session_id")
        )
    }

    private static func nestedString(_ dictionary: [String: Any], _ key: String, _ nestedKey: String) -> String? {
        guard let nested = dictionary[key] as? [String: Any] else { return nil }
        return nested[nestedKey] as? String
    }

    private static func firstString(_ values: Any?...) -> String? {
        for value in values {
            guard let string = value as? String else { continue }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func sessionStatusIsIdle(_ value: Any?) -> Bool {
        if let string = firstString(value) {
            return string == "idle"
        }
        guard let status = value as? [String: Any] else { return false }
        return firstString(status["type"], status["status"], status["state"]) == "idle"
    }

    private static func messageInfoHasCompletedTime(_ info: [String: Any]) -> Bool {
        guard let time = info["time"] as? [String: Any] else { return false }
        return time["completed"] != nil ||
            time["completedAt"] != nil ||
            time["end"] != nil ||
            time["ended"] != nil
    }

    private mutating func consumeMessageUpdated(_ properties: [String: Any]) -> [String] {
        let info = (properties["info"] as? [String: Any])
            ?? (properties["message"] as? [String: Any])
            ?? [:]
        guard let messageID = Self.firstString(info["id"], properties["messageID"], properties["messageId"]),
              let role = Self.firstString(info["role"], properties["role"]) else {
            return []
        }

        messageRoleByID[messageID] = role
        guard role == "assistant" else { return [] }
        let partIDs = messageIDByPartID.compactMap { partID, candidateMessageID in
            candidateMessageID == messageID ? partID : nil
        }
        return partIDs.flatMap { flushPart($0) }
    }

    private mutating func consumePartUpdated(_ properties: [String: Any]) -> [String] {
        guard let part = properties["part"] as? [String: Any],
              let partID = part["id"] as? String,
              let messageID = part["messageID"] as? String else {
            return []
        }

        messageIDByPartID[partID] = messageID
        guard part["type"] as? String == "text",
              part["ignored"] as? Bool != true else {
            return []
        }

        isTextPartByID[partID] = true
        guard let text = Self.firstString(part["text"], part["textDelta"], part["content"]) else {
            return []
        }

        let existingText = textByPartID[partID] ?? ""
        if text.count >= existingText.count {
            textByPartID[partID] = text
        }
        return flushPart(partID)
    }

    private mutating func consumePartDelta(_ properties: [String: Any]) -> [String] {
        guard properties["field"] as? String == "text",
              let partID = properties["partID"] as? String,
              let messageID = properties["messageID"] as? String,
              let delta = properties["delta"] as? String,
              !delta.isEmpty else {
            return []
        }

        messageIDByPartID[partID] = messageID
        textByPartID[partID, default: ""] += delta
        return flushPart(partID)
    }

    private mutating func flushPart(_ partID: String) -> [String] {
        guard isTextPartByID[partID] == true,
              let messageID = messageIDByPartID[partID],
              messageRoleByID[messageID] == "assistant",
              let text = textByPartID[partID],
              !text.isEmpty else {
            return []
        }

        let emittedCharacterCount = emittedCharacterCountByPartID[partID] ?? 0
        guard text.count > emittedCharacterCount else { return [] }
        emittedCharacterCountByPartID[partID] = text.count
        return [String(text.dropFirst(emittedCharacterCount))]
    }
}
