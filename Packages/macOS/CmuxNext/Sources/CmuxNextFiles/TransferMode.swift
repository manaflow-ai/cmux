/// Copy or move, as a drop or paste decides (Finder: same volume moves, another copies; Option copies, Command moves).
public enum TransferMode: String, Sendable, Hashable {
    /// The source stays.
    case copy
    /// The source goes.
    case move
}
