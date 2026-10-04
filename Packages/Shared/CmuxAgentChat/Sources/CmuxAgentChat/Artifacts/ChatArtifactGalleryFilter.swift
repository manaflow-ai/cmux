/// A sheet-wide artifact-kind filter applied within every gallery group.
public enum ChatArtifactGalleryFilter: String, CaseIterable, Sendable, Equatable {
    /// Includes every artifact, including kinds without a dedicated filter.
    case all
    /// Includes image artifacts.
    case images
    /// Includes source-code artifacts.
    case code
    /// Includes log and plain-text artifacts.
    case logs
    /// Includes document artifacts.
    case docs
    /// Includes directory artifacts.
    case folders
}
