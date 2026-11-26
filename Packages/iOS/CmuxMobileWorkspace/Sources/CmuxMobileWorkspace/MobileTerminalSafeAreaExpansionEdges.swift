public import SwiftUI

/// The set of edges a terminal should expand past the safe area into.
public struct MobileTerminalSafeAreaExpansionEdges: Equatable, Sendable {
    /// Whether the terminal should expand past the leading safe-area edge.
    public var leading: Bool
    /// Whether the terminal should expand past the trailing safe-area edge.
    public var trailing: Bool
    /// Whether the terminal should expand past the bottom safe-area edge.
    public var bottom: Bool

    /// Creates an expansion-edge set.
    /// - Parameters:
    ///   - leading: Whether to expand past the leading edge.
    ///   - trailing: Whether to expand past the trailing edge.
    ///   - bottom: Whether to expand past the bottom edge.
    public init(leading: Bool, trailing: Bool, bottom: Bool) {
        self.leading = leading
        self.trailing = trailing
        self.bottom = bottom
    }

    /// Creates an expansion-edge set that treats both horizontal edges alike.
    /// - Parameters:
    ///   - horizontal: Whether to expand across both horizontal edges.
    ///   - bottom: Whether to expand past the bottom edge.
    public init(horizontal: Bool, bottom: Bool) {
        self.init(leading: horizontal, trailing: horizontal, bottom: bottom)
    }

    /// Whether any edge expansion is requested.
    public var hasEdges: Bool {
        leading || trailing || bottom
    }

    /// The SwiftUI `Edge.Set` corresponding to the requested edges.
    public var edgeSet: Edge.Set {
        var edges: Edge.Set = []
        if leading {
            edges.formUnion(.leading)
        }
        if trailing {
            edges.formUnion(.trailing)
        }
        if bottom {
            edges.formUnion(.bottom)
        }
        return edges
    }
}
