import Foundation

public enum CmuxEventStreamRequestParseError: Error, Equatable {
    case invalidRequest
}

public struct CmuxEventStreamRequest: Sendable, Equatable {
    public let afterSequence: Int64?
    public let names: Set<String>
    public let categories: Set<String>
    public let includeHeartbeats: Bool

    public init(line: String) throws {
        guard let object = Self.jsonObject(line),
              object["method"] as? String == "events.stream" else {
            throw CmuxEventStreamRequestParseError.invalidRequest
        }

        let params = object["params"] as? [String: Any] ?? [:]
        afterSequence = CmuxEventBus.int64(params["after_seq"] ?? params["after"])
        names = Self.stringSet(params["names"] ?? params["name"])
        categories = Self.stringSet(params["categories"] ?? params["category"])
        includeHeartbeats = Self.boolParam(params["include_heartbeats"] ?? params["include_heartbeat"]) ?? true
    }

    public static func isStreamRequest(_ line: String) -> Bool {
        jsonObject(line)?["method"] as? String == "events.stream"
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func stringSet(_ value: Any?) -> Set<String> {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let values = value as? [String] {
            return Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        if let values = value as? [Any] {
            return Set(values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        return []
    }

    private static func boolParam(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            if number.compare(NSNumber(value: 0)) == .orderedSame { return false }
            if number.compare(NSNumber(value: 1)) == .orderedSame { return true }
            return nil
        }
        guard let string = value as? String else { return nil }
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }
}
