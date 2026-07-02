import Foundation

public struct CmuxExtensionAPIVersion: Codable, Comparable, Equatable, Sendable {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Baseline sidebar contract: the read/action scopes available since 2.0.
    public static let sidebarV2 = CmuxExtensionAPIVersion(major: 2, minor: 0)

    /// Sidebar contract 2.1: adds the `runWorkspaceCommand` action scope. Manifests
    /// that request scopes introduced here must declare at least this version so that
    /// hosts advertising only an older `supportedAPIVersion` reject them by version
    /// rather than by a scope-decoding failure.
    public static let sidebarV2_1 = CmuxExtensionAPIVersion(major: 2, minor: 1)

    public static func < (lhs: CmuxExtensionAPIVersion, rhs: CmuxExtensionAPIVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }
}
