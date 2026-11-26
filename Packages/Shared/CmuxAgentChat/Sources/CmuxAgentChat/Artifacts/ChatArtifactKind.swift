/// The preview category the Mac assigns to an artifact path.
public enum ChatArtifactKind: String, Sendable, Equatable, Codable {
    /// A raster image that can be thumbnailed and displayed.
    case image
    /// A UTF-8 text-like file.
    case text
    /// A file with no inline preview support.
    case binary
    /// A directory whose immediate entries can be listed when in scope.
    case directory
}
