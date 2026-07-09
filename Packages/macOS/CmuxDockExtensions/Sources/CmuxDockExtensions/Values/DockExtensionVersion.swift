import Foundation

/// A lenient dotted numeric version (`1`, `0.30`, `0.30.1`, `1.2.3.4`) used
/// for a manifest's `minCmuxVersion` gate against the running app version.
public struct DockExtensionVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    /// The version string as written.
    public let rawValue: String

    /// The parsed numeric components, most significant first.
    public let components: [Int]

    /// Parses a dotted numeric version: 1–4 components, each 1–6 digits.
    /// Returns `nil` for anything else (prerelease suffixes are not supported).
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            components.append(value)
        }
        self.rawValue = string
        self.components = components
    }

    public var description: String { rawValue }

    public static func < (lhs: DockExtensionVersion, rhs: DockExtensionVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: DockExtensionVersion, rhs: DockExtensionVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
