import Foundation

struct ChatToolReferencedPathExtractor: Sendable {
    private static let pathKeys: Set<String> = ["file_path", "notebook_path", "path"]
    /// Maximum number of distinct structured paths retained from one tool
    /// input. The bound is enforced while walking the JSON tree so a hostile
    /// array cannot first materialize an unbounded intermediate path list.
    static let maximumPathCount = 1_024
    /// Maximum UTF-8 size of one retained path, matching the artifact scope's
    /// lexical path ceiling.
    static let maximumPathBytes = 4_096
    /// Maximum aggregate UTF-8 size of paths retained for one tool input.
    static let maximumAggregatePathBytes = 64 * 1_024

    func referencedPaths(
        in value: TranscriptJSONValue?,
        maximumCount: Int = Self.maximumPathCount,
        maximumBytes: Int = Self.maximumAggregatePathBytes
    ) -> [String]? {
        guard let value else { return nil }
        let limit = min(maximumCount, Self.maximumPathCount)
        let byteLimit = min(maximumBytes, Self.maximumAggregatePathBytes)
        guard limit > 0, byteLimit > 0 else { return nil }
        var paths: [String] = []
        paths.reserveCapacity(limit)
        var seen: Set<String> = []
        seen.reserveCapacity(limit)
        var retainedBytes = 0
        _ = appendReferencedPaths(
            in: value,
            key: nil,
            into: &paths,
            seen: &seen,
            retainedBytes: &retainedBytes,
            maximumCount: limit,
            maximumBytes: byteLimit
        )
        return paths.isEmpty ? nil : paths
    }

    /// Returns a bounded, first-seen unique copy of already extracted paths.
    /// This protects parser carry-over and decoded legacy values in addition
    /// to the streaming JSON walk above.
    func boundedPaths(
        _ paths: [String]?,
        maximumCount: Int = Self.maximumPathCount,
        maximumBytes: Int = Self.maximumAggregatePathBytes
    ) -> [String]? {
        guard let paths else { return nil }
        let limit = min(maximumCount, Self.maximumPathCount)
        let byteLimit = min(maximumBytes, Self.maximumAggregatePathBytes)
        guard limit > 0, byteLimit > 0 else { return nil }
        var bounded: [String] = []
        bounded.reserveCapacity(min(paths.count, limit))
        var seen: Set<String> = []
        seen.reserveCapacity(min(paths.count, limit))
        var retainedBytes = 0
        for path in paths {
            if append(
                path,
                into: &bounded,
                seen: &seen,
                retainedBytes: &retainedBytes,
                maximumCount: limit,
                maximumBytes: byteLimit
            ) {
                break
            }
        }
        return bounded.isEmpty ? nil : bounded
    }

    @discardableResult
    private func appendReferencedPaths(
        in value: TranscriptJSONValue,
        key: String?,
        into paths: inout [String],
        seen: inout Set<String>,
        retainedBytes: inout Int,
        maximumCount: Int,
        maximumBytes: Int
    ) -> Bool {
        guard paths.count < maximumCount, retainedBytes < maximumBytes else { return true }
        if let key, Self.pathKeys.contains(key) {
            return appendStringValues(
                in: value,
                into: &paths,
                seen: &seen,
                retainedBytes: &retainedBytes,
                maximumCount: maximumCount,
                maximumBytes: maximumBytes
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
                    retainedBytes: &retainedBytes,
                    maximumCount: maximumCount,
                    maximumBytes: maximumBytes
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
                    retainedBytes: &retainedBytes,
                    maximumCount: maximumCount,
                    maximumBytes: maximumBytes
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
                    retainedBytes: &retainedBytes,
                    maximumCount: maximumCount,
                    maximumBytes: maximumBytes
                )
            }
        case .number, .bool, .null:
            break
        }
        return paths.count >= maximumCount || retainedBytes >= maximumBytes
    }

    @discardableResult
    private func appendStringValues(
        in value: TranscriptJSONValue,
        into paths: inout [String],
        seen: inout Set<String>,
        retainedBytes: inout Int,
        maximumCount: Int,
        maximumBytes: Int
    ) -> Bool {
        guard paths.count < maximumCount, retainedBytes < maximumBytes else { return true }
        switch value {
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return append(
                    trimmed,
                    into: &paths,
                    seen: &seen,
                    retainedBytes: &retainedBytes,
                    maximumCount: maximumCount,
                    maximumBytes: maximumBytes
                )
            }
        case .array(let array):
            for item in array {
                if appendStringValues(
                    in: item,
                    into: &paths,
                    seen: &seen,
                    retainedBytes: &retainedBytes,
                    maximumCount: maximumCount,
                    maximumBytes: maximumBytes
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
                    retainedBytes: &retainedBytes,
                    maximumCount: maximumCount,
                    maximumBytes: maximumBytes
                ) {
                    return true
                }
            }
        case .number, .bool, .null:
            break
        }
        return paths.count >= maximumCount || retainedBytes >= maximumBytes
    }

    private func append(
        _ path: String,
        into paths: inout [String],
        seen: inout Set<String>,
        retainedBytes: inout Int,
        maximumCount: Int,
        maximumBytes: Int
    ) -> Bool {
        guard paths.count < maximumCount, retainedBytes < maximumBytes else { return true }
        guard !seen.contains(path) else { return false }
        let pathBytes = path.utf8.count
        guard pathBytes <= Self.maximumPathBytes else { return false }
        guard pathBytes <= maximumBytes - retainedBytes else { return true }
        seen.insert(path)
        paths.append(path)
        retainedBytes += pathBytes
        return paths.count >= maximumCount || retainedBytes >= maximumBytes
    }

    private static func isAbsolutePathValue(_ value: String) -> Bool {
        value.hasPrefix("/") || value == "~" || value.hasPrefix("~/") || value.hasPrefix("file://")
    }
}
