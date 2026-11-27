public import Bonsplit

/// The split orientation persisted by cmux session snapshots.
public enum SessionSplitOrientation: String, Codable, Equatable, Sendable {
    /// Children arranged left to right.
    case horizontal
    /// Children arranged top to bottom.
    case vertical

    /// Captures a live Bonsplit split orientation.
    ///
    /// - Parameter orientation: The live split axis.
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
