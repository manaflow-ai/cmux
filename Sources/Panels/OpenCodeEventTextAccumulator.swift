import Foundation

struct OpenCodeEventTextAccumulator {
    private static let maxTrackedMessages = 16
    private static let maxTrackedPartTextCharacters = 256 * 1024

    private var messageRoleByID: [String: String] = [:]
    private var messageIDOrder: [String] = []
    private var messageIDByPartID: [String: String] = [:]
    private var isTextPartByID: [String: Bool] = [:]
    private var textByPartID: [String: String] = [:]
    private var storedTextStartOffsetByPartID: [String: Int] = [:]
    private var emittedCharacterCountByPartID: [String: Int] = [:]

    var retainedTextCharacterCountForTesting: Int {
        textByPartID.values.reduce(0) { partial, text in
            partial + text.count
        }
    }

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

    private static func firstContentString(_ values: Any?...) -> String? {
        var emptyString: String?
        for value in values {
            guard let string = value as? String else { continue }
            if !string.isEmpty {
                return string
            }
            if emptyString == nil {
                emptyString = string
            }
        }
        return emptyString
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

        rememberMessageID(messageID)
        messageRoleByID[messageID] = role
        guard role == "assistant" else { return [] }
        let partIDs = messageIDByPartID.compactMap { partID, candidateMessageID in
            candidateMessageID == messageID ? partID : nil
        }
        let output = partIDs.flatMap { flushPart($0) }
        if Self.messageInfoHasCompletedTime(info) ||
            Self.firstString(info["finish"], info["finishedReason"], properties["finish"]) != nil ||
            info["error"] != nil {
            pruneMessage(messageID)
        }
        return output
    }

    private mutating func consumePartUpdated(_ properties: [String: Any]) -> [String] {
        guard let part = properties["part"] as? [String: Any],
              let partID = part["id"] as? String,
              let messageID = part["messageID"] as? String else {
            return []
        }

        messageIDByPartID[partID] = messageID
        rememberMessageID(messageID)
        guard part["type"] as? String == "text",
              part["ignored"] as? Bool != true else {
            prunePart(partID)
            return []
        }

        isTextPartByID[partID] = true
        guard let text = Self.firstContentString(part["text"], part["textDelta"], part["content"]) else {
            return []
        }

        if text.count >= sourceCharacterCount(forPartID: partID) {
            storeBoundedText(text, sourceStartOffset: 0, forPartID: partID)
        }
        return flushFullText(text, partID: partID)
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
        rememberMessageID(messageID)
        if isTextPartByID[partID] == true,
           messageRoleByID[messageID] == "assistant" {
            emittedCharacterCountByPartID[partID, default: 0] += delta.count
            return [delta]
        }
        storeBoundedText(
            (textByPartID[partID] ?? "") + delta,
            sourceStartOffset: storedTextStartOffsetByPartID[partID] ?? 0,
            forPartID: partID
        )
        return flushPart(partID)
    }

    private mutating func flushFullText(_ text: String, partID: String) -> [String] {
        guard isTextPartByID[partID] == true,
              let messageID = messageIDByPartID[partID],
              messageRoleByID[messageID] == "assistant",
              !text.isEmpty else {
            return []
        }

        let emittedCharacterCount = emittedCharacterCountByPartID[partID] ?? 0
        guard text.count > emittedCharacterCount else { return [] }
        emittedCharacterCountByPartID[partID] = text.count
        return [String(text.dropFirst(emittedCharacterCount))]
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
        let storedStartOffset = storedTextStartOffsetByPartID[partID] ?? 0
        let storedEndOffset = storedStartOffset + text.count
        guard storedEndOffset > emittedCharacterCount else { return [] }
        let relativeStartOffset = max(0, emittedCharacterCount - storedStartOffset)
        guard relativeStartOffset < text.count else { return [] }
        emittedCharacterCountByPartID[partID] = storedEndOffset
        return [String(text.dropFirst(relativeStartOffset))]
    }

    private func sourceCharacterCount(forPartID partID: String) -> Int {
        max(
            emittedCharacterCountByPartID[partID] ?? 0,
            (storedTextStartOffsetByPartID[partID] ?? 0) + (textByPartID[partID]?.count ?? 0)
        )
    }

    private mutating func storeBoundedText(
        _ text: String,
        sourceStartOffset: Int,
        forPartID partID: String
    ) {
        let bounded = Self.boundedStoredText(text, sourceStartOffset: sourceStartOffset)
        textByPartID[partID] = bounded.text
        storedTextStartOffsetByPartID[partID] = bounded.sourceStartOffset
    }

    private mutating func rememberMessageID(_ messageID: String) {
        if !messageIDOrder.contains(messageID) {
            messageIDOrder.append(messageID)
        }
        while messageIDOrder.count > Self.maxTrackedMessages {
            pruneMessage(messageIDOrder[0])
        }
    }

    private mutating func pruneMessage(_ messageID: String) {
        messageRoleByID.removeValue(forKey: messageID)
        messageIDOrder.removeAll { $0 == messageID }
        let partIDs = messageIDByPartID.compactMap { partID, candidateMessageID in
            candidateMessageID == messageID ? partID : nil
        }
        for partID in partIDs {
            prunePart(partID)
        }
    }

    private mutating func prunePart(_ partID: String) {
        messageIDByPartID.removeValue(forKey: partID)
        isTextPartByID.removeValue(forKey: partID)
        textByPartID.removeValue(forKey: partID)
        storedTextStartOffsetByPartID.removeValue(forKey: partID)
        emittedCharacterCountByPartID.removeValue(forKey: partID)
    }

    private static func boundedStoredText(
        _ text: String,
        sourceStartOffset: Int
    ) -> (text: String, sourceStartOffset: Int) {
        guard text.count > maxTrackedPartTextCharacters else {
            return (text, sourceStartOffset)
        }
        let droppedCharacterCount = text.count - maxTrackedPartTextCharacters
        return (
            String(text.suffix(maxTrackedPartTextCharacters)),
            sourceStartOffset + droppedCharacterCount
        )
    }
}
