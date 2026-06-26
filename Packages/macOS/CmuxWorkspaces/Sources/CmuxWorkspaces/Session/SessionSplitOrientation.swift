public import Bonsplit

/// Persisted orientation of a workspace split node in a session snapshot.
///
/// Bridges Bonsplit's live ``SplitOrientation`` to a `Codable`, wire-stable
/// string enum so the restore format does not depend on the layout engine's
/// in-memory type.
public enum SessionSplitOrientation: String, Codable, Sendable {
    case horizontal
    case vertical

    /// Maps a live Bonsplit ``SplitOrientation`` onto its persisted form.
    public init(_ orientation: SplitOrientation) {
        switch orientation {
        case .horizontal:
            self = .horizontal
        case .vertical:
            self = .vertical
        }
    }

    /// The live Bonsplit ``SplitOrientation`` this persisted value restores to.
    public var splitOrientation: SplitOrientation {
        switch self {
        case .horizontal:
            return .horizontal
        case .vertical:
            return .vertical
        }
    }
}
