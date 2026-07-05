/// Produces safe directory names for Fleet task keys.
public struct FleetPathSanitizer: Sendable {
    /// The maximum character count for returned directory names.
    public var maxLength: Int

    /// The name returned when sanitization would otherwise be empty.
    public var fallback: String

    /// Creates a path sanitizer with deterministic limits.
    /// - Parameters:
    ///   - maxLength: The maximum character count for returned directory names.
    ///   - fallback: The name returned when sanitization would otherwise be empty.
    public init(maxLength: Int = 100, fallback: String = "task") {
        self.maxLength = maxLength
        self.fallback = fallback
    }

    /// Returns a filesystem-safe directory name for a task key.
    /// - Parameter key: The source task key to sanitize.
    /// - Returns: A non-empty safe directory name.
    public func directoryName(for key: String) -> String {
        let sanitizedKey = sanitizedName(for: key)
        if !sanitizedKey.isEmpty {
            return sanitizedKey
        }

        let sanitizedFallback = sanitizedName(for: fallback)
        return sanitizedFallback.isEmpty ? "task" : sanitizedFallback
    }

    private func sanitizedName(for value: String) -> String {
        guard maxLength > 0 else {
            return ""
        }

        var result = ""
        var previousWasReplacement = false

        for scalar in value.unicodeScalars {
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

        return result
    }

    private func isAllowed(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            true
        case 45, 46, 95:
            true
        default:
            false
        }
    }

    private func trimmed(_ value: String) -> String {
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

    private func shouldTrim(_ character: Character) -> Bool {
        character == "." || character == "_" || character == "-"
    }
}
