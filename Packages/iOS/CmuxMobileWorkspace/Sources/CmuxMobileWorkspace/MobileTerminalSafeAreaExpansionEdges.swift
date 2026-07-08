public import SwiftUI

/// The set of edges a terminal should expand past the safe area into.
public struct MobileTerminalSafeAreaExpansionEdges: Equatable, Sendable {
    /// Whether the terminal should expand across both horizontal safe-area edges.
    public var horizontal: Bool
    /// Whether the terminal should expand past the bottom safe-area edge.
    public var bottom: Bool

    /// Creates an expansion-edge set.
    /// - Parameters:
    ///   - horizontal: Whether to expand across the horizontal edges.
    ///   - bottom: Whether to expand past the bottom edge.
    public init(horizontal: Bool, bottom: Bool) {
        self.horizontal = horizontal
        self.bottom = bottom
    }

    /// Whether any edge expansion is requested.
    public var hasEdges: Bool {
        horizontal || bottom
    }

    /// The SwiftUI `Edge.Set` corresponding to the requested edges.
    public var edgeSet: Edge.Set {
        var edges: Edge.Set = []
        if horizontal {
            edges.formUnion(.horizontal)
        }
        if bottom {
            edges.formUnion(.bottom)
        }
        return edges
    }
}
