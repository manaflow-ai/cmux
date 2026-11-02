public import Foundation

/// A macOS version such as `26.0` or `15.6.1`. Appcast items carry `sparkle:minimumSystemVersion`
/// and the app bundle carries `LSMinimumSystemVersion` in this form; the update rules
/// (cmux-updater-core, ``UpdaterRules``) parse and compare them.
nonisolated public struct SystemVersion: Sendable, Hashable, Codable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(_ version: OperatingSystemVersion) {
        self.init(major: version.majorVersion, minor: version.minorVersion, patch: version.patchVersion)
    }

    /// The running system.
    public static var current: SystemVersion { SystemVersion(ProcessInfo.processInfo.operatingSystemVersion) }

    /// `26.0`, or `15.6.1` when the patch is set.
    public var description: String {
        patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }
}
