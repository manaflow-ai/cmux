import Foundation

/// Shared bounds for workspace metadata that travels between Mac and iOS.
public enum MobileWorkspaceMetadataLimits {
    /// Keep durable workspace descriptions well below the 8 MiB mobile frame cap.
    public static let customDescriptionMaxUTF8Bytes = 4096

    /// Normalizes line endings, treats blank text as nil, and caps descriptions
    /// by UTF-8 byte count without splitting a Swift `Character`.
    public static func normalizedCustomDescription(_ description: String?) -> String? {
        let normalizedLineEndings = description?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalizedLineEndings?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let normalizedLineEndings else { return nil }
        return truncatedUTF8(normalizedLineEndings, maxBytes: customDescriptionMaxUTF8Bytes)
    }

    /// Caps any already-normalized value before it is hashed or placed on the wire.
    public static func boundedCustomDescription(_ description: String?) -> String? {
        guard let description else { return nil }
        return normalizedCustomDescription(description)
    }

    private static func truncatedUTF8(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var result = ""
        result.reserveCapacity(min(value.count, maxBytes))
        var usedBytes = 0
        for character in value {
            let byteCount = String(character).utf8.count
            guard usedBytes + byteCount <= maxBytes else { break }
            result.append(character)
            usedBytes += byteCount
        }
        return result
    }
}
