/// Identifies how the engine resolved a changes baseline.
public enum ChangesBaseKind: String, Sendable, Equatable {
    /// The engine selected `HEAD`, with an empty-tree fallback for an unborn repository.
    case workingTree
    /// The caller supplied a concrete Git reference.
    case ref
}
