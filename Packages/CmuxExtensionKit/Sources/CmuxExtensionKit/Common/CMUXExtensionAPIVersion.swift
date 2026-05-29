import Foundation

public struct CMUXExtensionAPIVersion: Codable, Comparable, Equatable, Sendable {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static let sidebarV1 = CMUXExtensionAPIVersion(major: 1, minor: 0)

    public static func < (lhs: CMUXExtensionAPIVersion, rhs: CMUXExtensionAPIVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }
}
