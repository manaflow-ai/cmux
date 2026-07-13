import Foundation

/// A dotted numeric version such as `1`, `0.42`, or `1.2.3`.
///
/// Orchestration manifests carry two version strings: the template's own
/// `version` and the optional `minCmuxVersion` gate. Both use this loose
/// semver shape (1–3 numeric components, no prerelease/build suffixes) so
/// they stay trivially comparable across cmux releases.
public struct OrchestrationVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `"X"`, `"X.Y"`, or `"X.Y.Z"` with non-negative integer
    /// components. Returns nil for anything else (empty, signs, suffixes).
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        var numbers: [Int] = []
        for component in components {
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(component)
            else { return nil }
            numbers.append(number)
        }
        self.init(
            major: numbers[0],
            minor: numbers.count > 1 ? numbers[1] : 0,
            patch: numbers.count > 2 ? numbers[2] : 0
        )
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: OrchestrationVersion, rhs: OrchestrationVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
