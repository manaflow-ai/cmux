import Foundation

public struct CmuxExtensionAPIVersion: Codable, Comparable, Equatable, Sendable {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static let sidebarV2 = CmuxExtensionAPIVersion(major: 2, minor: 0)

    /// Sidebar API with native management, workspace groups, and agent observations.
    public static let sidebarV2_1 = CmuxExtensionAPIVersion(major: 2, minor: 1)

    /// Sidebar API with revision-guarded, host-owned project context.
    public static let sidebarV2_2 = CmuxExtensionAPIVersion(major: 2, minor: 2)

    public static func < (lhs: CmuxExtensionAPIVersion, rhs: CmuxExtensionAPIVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }
}
