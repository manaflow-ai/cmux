/// Persisted state for a file preview surface inside a session snapshot.
///
/// A pure leaf value carrying the previewed file's path. The on-disk wire
/// format is owned by the app's session snapshot; encoding stays byte-identical
/// to the legacy app-target definition (default `Codable` synthesis over the
/// single stored property).
public struct SessionFilePreviewPanelSnapshot: Codable, Sendable {
    /// The previewed file's path.
    public var filePath: String

    /// Creates a file preview panel snapshot for the given file path.
    public init(filePath: String) {
        self.filePath = filePath
    }
}
