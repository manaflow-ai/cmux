import Foundation

struct ChatToolReferencedPathExtractor: Sendable {
    private static let pathKeys: Set<String> = ["file_path", "notebook_path", "path"]
    /// Maximum number of distinct structured paths retained from one tool
    /// input. The bound is enforced while walking the JSON tree so a hostile
    /// array cannot first materialize an unbounded intermediate path list.
    static let maximumPathCount = 1_024

    func referencedPaths(
        in value: TranscriptJSONValue?,
        maximumCount: Int = Self.maximumPathCount
    ) -> [String]? {
        guard let value else { return nil }
        let limit = min(maximumCount, Self.maximumPathCount)
        guard limit > 0 else { return nil }
        var paths: [String] = []
        paths.reserveCapacity(limit)
        var seen: Set<String> = []
        seen.reserveCapacity(limit)
        _ = appendReferencedPaths(
            in: value,
            key: nil,
            into: &paths,
            seen: &seen,
            maximumCount: limit
        )
        return paths.isEmpty ? nil : paths
    }

    @discardableResult
    private func appendReferencedPaths(
        in value: TranscriptJSONValue,
        key: String?,
        into paths: inout [String],
        seen: inout Set<String>,
        maximumCount: Int
    ) -> Bool {
        guard paths.count < maximumCount else { return true }
        if let key, Self.pathKeys.contains(key) {
            return appendStringValues(
                in: value,
                into: &paths,
                seen: &seen,
                maximumCount: maximumCount
            )
        }
        switch value {
        case .object(let object):
            for (childKey, childValue) in object {
                if appendReferencedPaths(
                    in: childValue,
                    key: childKey,
                    into: &paths,
                    seen: &seen,
                    maximumCount: maximumCount
                ) {
                    return true
                }
            }
        case .array(let array):
            for item in array {
                if appendReferencedPaths(
                    in: item,
                    key: nil,
                    into: &paths,
                    seen: &seen,
                    maximumCount: maximumCount
                ) {
                    return true
                }
            }
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.isAbsolutePathValue(trimmed),
               !trimmed.contains(where: \.isWhitespace) {
                return append(
                    trimmed,
                    into: &paths,
                    seen: &seen,
                    maximumCount: maximumCount
                )
            }
        case .number, .bool, .null:
            break
        }
        return paths.count >= maximumCount
    }

    @discardableResult
    private func appendStringValues(
        in value: TranscriptJSONValue,
        into paths: inout [String],
        seen: inout Set<String>,
        maximumCount: Int
    ) -> Bool {
        guard paths.count < maximumCount else { return true }
        switch value {
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return append(
                    trimmed,
                    into: &paths,
                    seen: &seen,
                    maximumCount: maximumCount
                )
            }
        case .array(let array):
            for item in array {
                if appendStringValues(
                    in: item,
                    into: &paths,
                    seen: &seen,
                    maximumCount: maximumCount
                ) {
                    return true
                }
            }
        case .object(let object):
            for child in object.values {
                if appendStringValues(
                    in: child,
                    into: &paths,
                    seen: &seen,
                    maximumCount: maximumCount
                ) {
                    return true
                }
            }
        case .number, .bool, .null:
            break
        }
        return paths.count >= maximumCount
    }

    private func append(
        _ path: String,
        into paths: inout [String],
        seen: inout Set<String>,
        maximumCount: Int
    ) -> Bool {
        guard paths.count < maximumCount else { return true }
        guard seen.insert(path).inserted else { return false }
        paths.append(path)
        return paths.count >= maximumCount
    }

    private static func isAbsolutePathValue(_ value: String) -> Bool {
        value.hasPrefix("/") || value == "~" || value.hasPrefix("~/") || value.hasPrefix("file://")
    }
}
