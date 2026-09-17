import Foundation

struct ChatToolReferencedPathExtractor: Sendable {
    private static let pathKeys: Set<String> = ["file_path", "notebook_path", "path"]

    func referencedPaths(in value: TranscriptJSONValue?) -> [String]? {
        guard let value else { return nil }
        var paths: [String] = []
        appendReferencedPaths(in: value, key: nil, into: &paths)
        let deduplicated = deduplicated(paths)
        return deduplicated.isEmpty ? nil : deduplicated
    }

    private func appendReferencedPaths(
        in value: TranscriptJSONValue,
        key: String?,
        into paths: inout [String]
    ) {
        if let key, Self.pathKeys.contains(key) {
            appendStringValues(in: value, into: &paths)
            return
        }
        switch value {
        case .object(let object):
            for (childKey, childValue) in object {
                appendReferencedPaths(in: childValue, key: childKey, into: &paths)
            }
        case .array(let array):
            for item in array {
                appendReferencedPaths(in: item, key: nil, into: &paths)
            }
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isAbsolutePathValue(trimmed),
               !trimmed.contains(where: \.isWhitespace) {
                paths.append(trimmed)
            }
        case .number, .bool, .null:
            return
        }
    }

    private func appendStringValues(in value: TranscriptJSONValue, into paths: inout [String]) {
        switch value {
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                paths.append(trimmed)
            }
        case .array(let array):
            for item in array {
                appendStringValues(in: item, into: &paths)
            }
        case .object(let object):
            for child in object.values {
                appendStringValues(in: child, into: &paths)
            }
        case .number, .bool, .null:
            return
        }
    }

    private func deduplicated(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths where !seen.contains(path) {
            seen.insert(path)
            result.append(path)
        }
        return result
    }

    private static func isAbsolutePathValue(_ value: String) -> Bool {
        value.hasPrefix("/") || value == "~" || value.hasPrefix("~/") || value.hasPrefix("file://")
    }
}
