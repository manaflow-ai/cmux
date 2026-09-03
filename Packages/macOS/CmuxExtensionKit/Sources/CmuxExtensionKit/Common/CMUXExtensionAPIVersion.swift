import Foundation

/// A major/minor version of the public extension manifest and wire contract.
public struct CmuxExtensionAPIVersion: Codable, Comparable, Equatable, Sendable {
    /// Compatibility family. Hosts reject a different major version.
    public var major: Int
    /// Backward-compatible feature level within the major version.
    public var minor: Int

    /// Creates an API version from its major and minor components.
    ///
    /// Manifest validation rejects negative components before a plugin loads.
    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// The current ExtensionKit sidebar API.
    public static let sidebarV2 = CmuxExtensionAPIVersion(major: 2, minor: 0)

    /// The first version of the general, process-backed plugin API.
    ///
    /// Sidebar extensions continue to use ``sidebarV2``. Keeping the plugin
    /// protocol on its own major version lets the host reject a manifest that
    /// was written for a newer wire contract without changing the existing
    /// ExtensionKit compatibility check.
    public static let pluginV3 = CmuxExtensionAPIVersion(major: 3, minor: 0)

    /// The newest API implemented by this build of CmuxExtensionKit.
    public static let current = CmuxExtensionAPIVersion.pluginV3

    /// Whether a host implementing `supported` can satisfy this minimum API.
    public func isCompatible(with supported: CmuxExtensionAPIVersion) -> Bool {
        major == supported.major && self <= supported
    }

    /// Orders versions by major component and then minor component.
    public static func < (lhs: CmuxExtensionAPIVersion, rhs: CmuxExtensionAPIVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }
}
