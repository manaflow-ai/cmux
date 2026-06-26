import Foundation

/// How a workspace lays out its panels.
enum WorkspaceLayoutMode: String, Codable, Sendable {
    /// The default bonsplit split-tree layout.
    case splits
    /// The freeform 2D canvas layout.
    case canvas
    /// A Niri-style horizontal page strip implemented by a native AppKit page host.
    case niri

    /// Whether this mode is rendered by the canvas host rather than bonsplit.
    var usesCanvasHost: Bool {
        switch self {
        case .canvas, .niri:
            return true
        case .splits:
            return false
        }
    }

    /// Next mode used by the hidden layout-cycle action.
    var nextCycledMode: WorkspaceLayoutMode {
        switch self {
        case .splits:
            return .canvas
        case .canvas:
            return .niri
        case .niri:
            return .splits
        }
    }
}
