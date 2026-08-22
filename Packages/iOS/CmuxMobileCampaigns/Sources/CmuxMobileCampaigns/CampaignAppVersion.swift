internal import Foundation

/// A dotted numeric marketing version ("1.0.5"), compared per component with
/// missing components treated as zero (1.0 == 1.0.0 < 1.0.5).
public struct CampaignAppVersion: Sendable, Equatable, Comparable, Decodable, CustomStringConvertible {
    public let components: [Int]
    public let description: String

    /// Fails on anything but dot-separated decimal integers.
    public init?(parsing string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var parsed: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        components = parsed
        description = trimmed
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let version = CampaignAppVersion(parsing: value) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "expected a dotted numeric version, got \(value)"
            ))
        }
        self = version
    }

    public static func < (lhs: CampaignAppVersion, rhs: CampaignAppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: CampaignAppVersion, rhs: CampaignAppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
