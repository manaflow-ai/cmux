public import Foundation

/// A cmux config file's filesystem location, used to perform the path
/// arithmetic that resolves button-icon image references against it.
///
/// Construct it with the config file path, then read ``projectRoot`` (the
/// directory that bounds where a project-local config may load images from) or
/// call ``resolve(_:)`` to anchor a relative image path to the config's
/// directory.
public struct CmuxConfigImagePath: Sendable {
    /// The path to the config file whose location anchors resolution.
    public let configSourcePath: String

    /// Creates a resolver anchored at `configSourcePath`.
    public init(configSourcePath: String) {
        self.configSourcePath = configSourcePath
    }

    /// The directory that bounds project-local image loading: the config's
    /// parent directory, or its grandparent when the config lives inside a
    /// `.cmux` directory.
    public var projectRoot: String {
        let configDir = (configSourcePath as NSString).deletingLastPathComponent
        if (configDir as NSString).lastPathComponent == ".cmux" {
            return (configDir as NSString).deletingLastPathComponent
        }
        return configDir
    }

    /// Expands `path` (resolving `~`) and, when it is relative, anchors it to
    /// the directory containing this config. Absolute paths are returned
    /// expanded but otherwise unchanged.
    public func resolve(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return expanded
        }
        let base = (configSourcePath as NSString).deletingLastPathComponent
        return (base as NSString).appendingPathComponent(expanded)
    }
}

extension Optional where Wrapped == CmuxConfigImagePath {
    /// Expands `path` (resolving `~`) and, when it is relative and a config
    /// anchor is present, anchors it to the directory containing the config.
    /// Absolute paths and the no-config case are returned expanded but
    /// otherwise unchanged.
    func resolve(_ path: String) -> String {
        if let self {
            return self.resolve(path)
        }
        return (path as NSString).expandingTildeInPath
    }
}
