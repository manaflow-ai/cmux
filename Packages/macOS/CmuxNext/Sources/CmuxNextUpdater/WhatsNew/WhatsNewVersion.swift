/// A What's New version: `X.Y.Z`, `X.Y.Z-rc.N` or `X.Y.Z-nightly.N`.
/// Order: by X.Y.Z, then a prerelease before its stable release, then the
/// prerelease number (an rc and a nightly of one X.Y.Z order by number).
nonisolated public struct WhatsNewVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// The prerelease kind and number, or nil for a stable release.
    public var prerelease: (kind: String, number: UInt64)?

    public init?(_ text: String) {
        let (core, suffix) = text.firstIndex(of: "-").map { (text[..<$0], Optional(text[text.index(after: $0)...])) } ?? (Substring(text), nil)
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard numbers.count == 3, let major = numbers[0], let minor = numbers[1], let patch = numbers[2],
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        if let suffix {
            let parts = suffix.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "rc" || parts[0] == "nightly", let number = UInt64(parts[1]) else { return nil }
            prerelease = (String(parts[0]), number)
        }
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.map { "\(core)-\($0.kind).\($0.number)" } ?? core
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
            && lhs.prerelease?.kind == rhs.prerelease?.kind && lhs.prerelease?.number == rhs.prerelease?.number
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(description)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let left = (lhs.major, lhs.minor, lhs.patch), right = (rhs.major, rhs.minor, rhs.patch)
        if left != right { return left < right }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (l?, r?): return l.number != r.number ? l.number < r.number : l.kind < r.kind
        }
    }
}
