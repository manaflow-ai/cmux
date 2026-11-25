public import Foundation
import CmuxNextWindowRules

/// A macOS version such as `26.0` or `15.6.1`, compared numerically.
///
/// Appcast items carry `sparkle:minimumSystemVersion` and the app bundle
/// carries `LSMinimumSystemVersion` in this form. Missing components count
/// as zero, so `26` equals `26.0.0`.
nonisolated public struct SystemVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses `"26"`, `"26.0"` or `"15.6.1"`; nil for anything else. The rule is cmux-updater-core's
    /// (`system_version.rs`), asked over the app FFI (`updater_system_version`).
    public init?(_ text: String) {
        struct Request: Encodable { var texts: [String] }
        struct Reply: Decodable { var versions: [WireSystemVersion?] }
        guard let reply = WindowRules().call("updater_system_version", Request(texts: [text]), as: Reply.self),
              let parsed = reply.versions.first, let parsed else { return nil }
        self = parsed.version
    }

    public init(_ version: OperatingSystemVersion) {
        self.init(major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion)
    }

    /// The running system.
    public static var current: SystemVersion { SystemVersion(ProcessInfo.processInfo.operatingSystemVersion) }

    public static func < (lhs: SystemVersion, rhs: SystemVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// `26.0`, or `15.6.1` when the patch is set.
    public var description: String {
        patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }
}
