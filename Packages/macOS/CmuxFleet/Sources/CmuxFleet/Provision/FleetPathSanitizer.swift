/// Produces safe directory names for Fleet task keys.
public struct FleetPathSanitizer: Sendable {
    /// Returns a filesystem-safe directory name for a task key.
    /// - Parameters:
    ///   - key: The source task key to sanitize.
    ///   - maxLength: The maximum character count for the returned name.
    /// - Returns: A non-empty safe directory name.
    public static func directoryName(for key: String, maxLength: Int = 100) -> String {
        guard maxLength > 0 else {
            return "task"
        }

        var result = ""
        var previousWasReplacement = false

        for scalar in key.unicodeScalars {
            if isAllowed(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasReplacement = false
            } else if !previousWasReplacement {
                result.append("_")
                previousWasReplacement = true
            }
        }

        result = trimmed(result)
        if result.count > maxLength {
            let end = result.index(result.startIndex, offsetBy: maxLength)
            result = String(result[..<end])
            result = trimmed(result)
        }

        return result.isEmpty ? "task" : result
    }

    private static func isAllowed(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            true
        case 45, 46, 95:
            true
        default:
            false
        }
    }

    private static func trimmed(_ value: String) -> String {
        var start = value.startIndex
        var end = value.endIndex

        while start < end, shouldTrim(value[start]) {
            start = value.index(after: start)
        }
        while end > start {
            let previous = value.index(before: end)
            if !shouldTrim(value[previous]) {
                break
            }
            end = previous
        }

        return String(value[start..<end])
    }

    private static func shouldTrim(_ character: Character) -> Bool {
        character == "." || character == "_" || character == "-"
    }
}
