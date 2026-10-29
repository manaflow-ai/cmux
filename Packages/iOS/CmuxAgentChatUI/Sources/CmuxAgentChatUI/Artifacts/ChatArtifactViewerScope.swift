/// The user-facing context in which an artifact preview is presented.
public enum ChatArtifactViewerScope: Sendable, Equatable {
    /// An artifact referenced by an agent chat transcript.
    case chat

    /// An artifact opened from a terminal surface.
    case terminal

    /// The file displayed by a markdown or file-preview panel.
    case panel

    /// A base or working-tree file opened from Workspace Changes.
    case workspaceChanges
}
