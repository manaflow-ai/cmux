/// A sheet-wide ordering applied independently within every artifact group.
public enum ChatArtifactGallerySort: String, CaseIterable, Sendable, Equatable {
    /// Preserves the host's descending last-reference sequence order.
    case recent
    /// Orders names ascending, case-insensitively.
    case name
    /// Orders known sizes largest-first, followed by unknown sizes.
    case size
}
