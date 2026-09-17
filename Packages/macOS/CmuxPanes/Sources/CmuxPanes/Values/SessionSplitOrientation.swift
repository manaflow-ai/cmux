public import Bonsplit

/// The split orientation persisted by cmux session snapshots.
public enum SessionSplitOrientation: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical

    /// Converts the persisted value used by session snapshots to Bonsplit's
    /// live split orientation.
    public init(_ orientation: SplitOrientation) {
        switch orientation {
        case .horizontal:
            self = .horizontal
        case .vertical:
            self = .vertical
        }
    }

    /// The Bonsplit orientation represented by this snapshot value.
    public var splitOrientation: SplitOrientation {
        switch self {
        case .horizontal:
            return .horizontal
        case .vertical:
            return .vertical
        }
    }
}
