public import Foundation

/// A required backend bundle item that could not be used.
public enum BackendServiceMissingBundleItem: Equatable, Sendable {
    /// The launch-agent property list was absent or unreadable.
    case propertyList(URL)

    /// The terminal backend executable was absent or not executable.
    case executable(URL)
}
