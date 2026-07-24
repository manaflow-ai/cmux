import Foundation

/// Mobile-safe projection of a Mac-authored workspace description.
public struct MobileWorkspaceDescriptionProjection: Equatable, Sendable {
    /// The bounded string sent to iOS, or nil when no description is set.
    public let value: String?
    /// Whether ``value`` omits bytes from the Mac's full durable description.
    public let isTruncated: Bool

    public init(value: String?, isTruncated: Bool) {
        self.value = value
        self.isTruncated = isTruncated
    }
}

/// Shared bounds for workspace metadata that travels between Mac and iOS.
public enum MobileWorkspaceMetadataLimits {
    /// Keep durable workspace descriptions well below the 8 MiB mobile frame cap.
    public static let customDescriptionMaxUTF8Bytes = 4096
    /// Color values accepted from mobile should be short names or `#RRGGBB`.
    public static let customColorMaxUTF8Bytes = 64

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
        projectedCustomDescription(description).value
    }

    /// Returns a mobile-safe description plus whether the Mac value was longer
    /// than the mobile transport cap. iOS uses the flag to avoid overwriting an
    /// unbounded Mac description with its bounded display projection.
    public static func projectedCustomDescription(
        _ description: String?
    ) -> MobileWorkspaceDescriptionProjection {
        guard let description else {
            return MobileWorkspaceDescriptionProjection(value: nil, isTruncated: false)
        }
        let normalizedLineEndings = description
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalizedLineEndings.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MobileWorkspaceDescriptionProjection(value: nil, isTruncated: false)
        }
        let isTruncated = normalizedLineEndings.utf8.count > customDescriptionMaxUTF8Bytes
        return MobileWorkspaceDescriptionProjection(
            value: truncatedUTF8(normalizedLineEndings, maxBytes: customDescriptionMaxUTF8Bytes),
            isTruncated: isTruncated
        )
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
