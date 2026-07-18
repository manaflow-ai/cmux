public import Foundation

/// A required backend bundle item that could not be used.
public enum BackendServiceMissingBundleItem: Equatable, Sendable {
    /// The launch-agent property list was absent or unreadable.
    case propertyList(URL)

    /// The terminal backend executable was absent or not executable.
    case executable(URL)

    /// The terminal renderer sibling was absent or not executable.
    case rendererExecutable(URL)

    /// The backend build-ID sidecar was absent or unreadable.
    case backendBuildID(URL)

    /// The renderer build-ID sidecar was absent or unreadable.
    case rendererBuildID(URL)

    /// A packaged artifact is a symlink, non-regular file, or has unsafe write permissions.
    case invalidArtifact(URL)
}
