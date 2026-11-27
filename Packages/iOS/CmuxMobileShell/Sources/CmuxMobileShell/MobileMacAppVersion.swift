/// A strictly numeric dotted Mac marketing version used by the mobile update advisor.
///
/// Valid versions contain one to three nonnegative decimal components. Missing trailing
/// components compare as zero, so `0.65` and `0.65.0` are equal.
public struct MobileMacAppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    /// The one to three numeric components parsed from the marketing version.
    public let components: [Int]

    /// Creates a version from a strictly numeric dotted marketing-version string.
    ///
    /// - Parameter string: A version containing one to three ASCII-decimal components.
    /// - Returns: A parsed version, or `nil` for an empty, malformed, signed, suffixed, or oversized version.
    public init?(parsing string: String) {
        let substrings = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(substrings.count) else { return nil }

        var parsedComponents: [Int] = []
        parsedComponents.reserveCapacity(substrings.count)
        for substring in substrings {
            guard !substring.isEmpty,
                  substring.utf8.allSatisfy({ (48 ... 57).contains($0) }),
                  let component = Int(substring)
            else {
                return nil
            }
            parsedComponents.append(component)
        }

        components = parsedComponents
    }

    /// The canonical dotted representation of the parsed numeric components.
    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    /// Returns whether two versions have equal numeric components after adding trailing zeroes.
    ///
    /// - Parameters:
    ///   - lhs: The first version to compare.
    ///   - rhs: The second version to compare.
    /// - Returns: `true` when both versions represent the same numeric version.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    /// Returns whether the first version numerically precedes the second version.
    ///
    /// - Parameters:
    ///   - lhs: The first version to compare.
    ///   - rhs: The second version to compare.
    /// - Returns: `true` when `lhs` is numerically older than `rhs`.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0 ..< 3 {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}
