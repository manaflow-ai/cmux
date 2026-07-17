/// Selects the baseline used to compare a repository's current working tree.
public enum ChangesBase: Sendable, Equatable {
    /// Compares the current working tree with `HEAD`, or the empty tree before the first commit.
    case workingTree
    /// Compares the current working tree with the supplied commit or tree reference.
    case ref(String)
}
