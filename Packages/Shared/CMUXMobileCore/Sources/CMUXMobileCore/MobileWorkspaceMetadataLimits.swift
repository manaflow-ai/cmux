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
    /// Keep all workspace descriptions in one mobile list frame bounded after
    /// JSON escaping. This leaves most of the 8 MiB frame cap for pre-existing
    /// row, group, terminal, and envelope fields.
    public static let customDescriptionsAggregateMaxJSONEscapedUTF8Bytes = 1 * 1024 * 1024
    /// Color values accepted from mobile should be short names or `#RRGGBB`.
    public static let customColorMaxUTF8Bytes = 64

    /// Normalizes line endings, treats blank text as nil, and caps descriptions
    /// by UTF-8 byte count without splitting a Swift `Character`.
    public static func normalizedCustomDescription(_ description: String?) -> String? {
        boundedNormalizedDescription(description).value
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
        boundedNormalizedDescription(description)
    }

    /// Applies a shared frame-level budget to an already-normalized projection.
    ///
    /// The budget is measured in the conservative number of UTF-8 bytes the
    /// description value can add once JSON string escaping is applied. Values
    /// that cannot fit are omitted or shortened and marked truncated so iOS
    /// treats the row as a read-only display projection of the Mac value.
    public static func projection(
        _ projection: MobileWorkspaceDescriptionProjection,
        constrainedToJSONEscapedUTF8Budget remainingBudget: inout Int
    ) -> MobileWorkspaceDescriptionProjection {
        guard let value = projection.value else {
            return projection
        }
        let byteCount = jsonEscapedUTF8ByteCount(value)
        if byteCount <= remainingBudget {
            remainingBudget -= byteCount
            return projection
        }
        guard remainingBudget > 0 else {
            return MobileWorkspaceDescriptionProjection(value: nil, isTruncated: true)
        }

        var result = ""
        result.reserveCapacity(min(value.utf8.count, remainingBudget))
        var usedBytes = 0
        var foundNonWhitespace = false
        var index = value.startIndex
        while index < value.endIndex {
            let nextIndex = value.index(after: index)
            let character = String(value[index])
            let characterByteCount = jsonEscapedUTF8ByteCount(character)
            guard usedBytes + characterByteCount <= remainingBudget else { break }
            result.append(contentsOf: character)
            usedBytes += characterByteCount
            if !foundNonWhitespace,
               character.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil {
                foundNonWhitespace = true
            }
            index = nextIndex
        }
        remainingBudget -= usedBytes
        guard foundNonWhitespace else {
            return MobileWorkspaceDescriptionProjection(value: nil, isTruncated: true)
        }
        return MobileWorkspaceDescriptionProjection(value: result, isTruncated: true)
    }

    /// Conservative UTF-8 byte count for a string once encoded as JSON string
    /// contents, excluding the surrounding quotes and object-key overhead.
    public static func jsonEscapedUTF8ByteCount(_ value: String) -> Int {
        var byteCount = 0
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22, 0x5c:
                byteCount += 2
            case 0x00..<0x20:
                byteCount += 6
            default:
                byteCount += scalar.utf8.count
            }
        }
        return byteCount
    }

    private static func boundedNormalizedDescription(
        _ description: String?
    ) -> MobileWorkspaceDescriptionProjection {
        guard let description else {
            return MobileWorkspaceDescriptionProjection(value: nil, isTruncated: false)
        }
        var result = ""
        result.reserveCapacity(customDescriptionMaxUTF8Bytes)
        var usedBytes = 0
        var isTruncated = false
        var foundNonWhitespace = false
        var index = description.startIndex

        while index < description.endIndex {
            let normalizedCharacter: String
            let character = description[index]
            let nextIndex = description.index(after: index)
            if character == "\r\n" {
                normalizedCharacter = "\n"
                index = nextIndex
            } else if character == "\r" {
                normalizedCharacter = "\n"
                if nextIndex < description.endIndex, description[nextIndex] == "\n" {
                    index = description.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
            } else {
                normalizedCharacter = String(character)
                index = nextIndex
            }

            if !foundNonWhitespace,
               normalizedCharacter.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil {
                foundNonWhitespace = true
            }

            let byteCount = normalizedCharacter.utf8.count
            if usedBytes + byteCount <= customDescriptionMaxUTF8Bytes {
                result.append(normalizedCharacter)
                usedBytes += byteCount
                if usedBytes == customDescriptionMaxUTF8Bytes, index < description.endIndex {
                    isTruncated = true
                }
            } else {
                isTruncated = true
            }

            if isTruncated {
                break
            }
        }

        guard foundNonWhitespace else {
            return MobileWorkspaceDescriptionProjection(value: nil, isTruncated: isTruncated)
        }
        return MobileWorkspaceDescriptionProjection(
            value: result,
            isTruncated: isTruncated
        )
    }
}
